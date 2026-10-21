//! The keymap: one frame's input, turned into what the reader should do.
//!
//! Separated from the reader so that every binding can be tested without a
//! window, a device, or a document -- which is the only way a keymap this
//! size stays correct. `read.zig` calls `command` and switches on the answer;
//! it never asks which key was pressed.
//!
//! ## Modes
//!
//! Vim's, because a reader that is also an editor has the same problem Vim
//! solved: the same few keys have to mean "move" while reading and "change"
//! while editing, and a mode is the honest way to say which.
//!
//! * **normal** -- reading. Scrolling, the cursor, windows, and the one-key
//!   highlight of a line. Where the reader starts and where `escape` returns.
//! * **visual** -- selecting. `v` drops an anchor at the cursor and every
//!   motion extends the selection from it; `V` selects whole lines. `m` or
//!   enter highlights the selection, `d` removes highlights under it, a digit
//!   highlights it in that colour.
//! * **edit** -- changing marks that exist. `i` walks to the mark at or after
//!   the cursor; `n` and `N` go between them; a digit recolours, `d` deletes,
//!   `a` starts a note.
//! * **draw** -- freehand ink. `d` enters it and the pointer is a pen; a digit
//!   picks the colour, `[` and `]` change its width. Nothing is bound to a
//!   motion here because the hand is on the mouse, which is the argument for
//!   it being a mode at all: a drag over the page means a stroke here and a
//!   selection everywhere else, and there is no way to say which but to say
//!   which.
//! * **note** -- typing. Every printable key is text, enter keeps it, escape
//!   throws it away.
//!
//! `u` and `<C-r>` undo and redo in every mode that is not typing: an undo is
//! not a thing that should need a mode change first, and a stroke drawn wrong
//! is undone from draw mode without leaving it.
//!
//! Search is not a mode. `/` opens a bar that takes the keyboard by having
//! focus, the way the palette does, so the keymap stands aside while it is
//! being typed into without anything here having to know. See
//! `Command.search_step` for why `n` means two things.
//!
//! The mode is changed *here*, as each key is read, so that `vjjm` typed
//! faster than a frame still means select-down-down-highlight. The reader may
//! overrule a change it cannot honour -- edit mode on a document with no
//! highlights goes straight back to normal -- and does so by writing `mode`.
//!
//! ## Prefixes
//!
//! Window commands are `<C-w>` followed by a key, and tabpages are `g`
//! followed by one, both in normal mode. A prefix that is never completed
//! times out after `prefix_timeout`, the way a terminal's escape sequences do.
//!
//! The two are read from different places and have to be. `<C-w>` cannot come
//! from typed text -- no platform sends text for a key held with ctrl -- which
//! is what `Input.chorded` and the `char` on a key event exist for. `g` is a
//! letter somebody typed, so it is read where the letters are, in the loop
//! over the frame's text; that is also what keeps `gt` and `gT` apart, since
//! `typedKey` folds case on purpose and a codepoint does not.
//! See `thviti/input.zig`.

const std = @import("std");

const thviti = @import("../thviti.zig");
const Layout = @import("Layout.zig");
const View = @import("View.zig");

const Input = thviti.Input;

/// How long a half-typed `<C-w>` waits for its second key.
pub const prefix_timeout: f32 = 2.0;

pub const Mode = enum {
    normal,
    visual,
    visual_line,
    edit,
    /// Freehand ink: the pointer is a pen, and a drag is a stroke.
    draw,
    note,
    /// The `:` line: a command typed out, run on enter. Built-in commands and
    /// the ones plugins register both live here.
    command,

    pub fn isVisual(m: Mode) bool {
        return m == .visual or m == .visual_line;
    }

    /// What the title bar says, in Vim's words.
    pub fn label(m: Mode) []const u8 {
        return switch (m) {
            .normal => "",
            .visual => "-- VISUAL --",
            .visual_line => "-- VISUAL LINE --",
            .edit => "-- EDIT --",
            .draw => "-- DRAW --",
            .note => "-- NOTE --",
            .command => ":",
        };
    }
};

/// The colours a digit picks, in the order printed on the keyboard. The first
/// is `0`'s absence: `1` is the accent colour, which the reader supplies.
pub const palette_size = 8;

pub const Command = union(enum) {
    none,
    /// Close the focused window, or the reader if it is the last one.
    quit,
    /// Leave the reader whatever is open.
    quit_all,

    // -- windows
    split: Layout.Direction,
    close_window,
    only_window,
    focus_side: Layout.Side,
    cycle_window: bool,
    equalise,

    // -- tabpages
    /// A tabpage holding one window on whatever this one is looking at.
    new_tab,
    /// Close the tabpage on screen. Refused when it is the only one, as in
    /// Vim: leaving the reader is what `q` is for.
    close_tab,
    /// `gt` and `gT`: forwards or backwards along the bar, wrapping.
    go_tab: i32,
    /// `<C-w>T`: move the focused window into a tabpage of its own.
    window_to_tab,

    // -- buffers
    next_buffer,
    previous_buffer,

    // -- moving
    /// Document pixels, not lines and not notches. How far a notch of the
    /// wheel is worth is a platform preference -- Windows has a system
    /// setting for it and Wayland sends the distance outright -- so it is
    /// decided in the platform layer and arrives here already converted.
    scroll_pixels: f32,
    scroll_screens: f32,
    to_start,
    to_end,
    next_page,
    previous_page,

    // -- zoom
    zoom_by: f32,
    zoom_to: f32,
    /// Tie the zoom to the shape of the window, or let it go free again.
    fit: View.Fit,

    // -- the cursor
    move_cursor: View.Step,
    hide_cursor,

    // -- modes. Each is sent when the mode has just changed, so the reader
    // can set up what the mode needs: an anchor, a focused highlight.
    enter_visual,
    enter_visual_line,
    enter_edit,
    enter_draw,
    enter_note,
    /// Back to normal from any mode, abandoning what was in progress.
    leave_mode,

    // -- visual
    /// `o`: the cursor goes to the other end of the selection.
    swap_selection_ends,
    /// Highlight the selection, in the accent colour or a palette colour.
    highlight_selection: ?u8,
    /// Remove every highlight the selection touches.
    unhighlight_selection,

    // -- normal
    /// Highlight the cursor's line, or remove the highlight under the cursor.
    toggle_highlight,
    clear_highlights,

    // -- edit
    next_mark,
    previous_mark,
    recolour_mark: u8,
    delete_mark,

    // -- draw
    /// The pen's colour, by its place in the palette. The same index a digit
    /// means everywhere else; see `paletteCommand`.
    pen_colour: u8,
    /// The pen's width, as a factor on what it is now -- the shape `zoom_by`
    /// has, and for the same reason: `[` and `]` are pressed repeatedly and
    /// the steps should compound rather than march.
    pen_width: f32,

    // -- note
    note_char: u21,
    note_backspace,
    note_commit,

    // -- the command line
    enter_command,
    command_char: u21,
    command_backspace,
    command_run,
    /// The palette: the same commands, listed and filtered rather than
    /// spelled out. `<C-p>`, which is a chord and not a letter, so it works
    /// in every mode that is not typing -- a person who cannot remember a
    /// command's name cannot be asked to leave visual mode to look it up.
    show_commands,

    // -- search
    /// `/`: the search bar, which does not exist until this arrives.
    enter_search,
    /// `n` and `N`.
    ///
    /// `n` has been the next page since the reader was a scroller, and in
    /// Vim it is the next match. Both, and which one depends on whether a
    /// search is live: with the bar open `n` steps through the matches, and
    /// with it closed it turns the page as it always did. `<space>` is the
    /// next page either way, so the page keys never go anywhere, and escape
    /// ends the search and gives `n` back.
    search_step: bool,

    /// A key a plugin has bound, by the id its runtime gave the binding.
    plugin_key: u32,

    // -- history
    undo,
    redo,
};

/// A key that has been pressed and is waiting for the one after it.
pub const Prefix = enum {
    none,
    /// `<C-w>`: windows.
    window,
    /// `g`: tabpages.
    g,
};

/// What survives between frames.
pub const State = struct {
    mode: Mode = .normal,
    /// Which prefix has been pressed and not yet completed.
    pending: Prefix = .none,
    /// Seconds the prefix has been waiting.
    waited: f32 = 0,
};

/// At most this many commands come out of one frame. A frame that saw more
/// keys than this is a frame after a breakpoint, and dropping the tail is
/// better than scrolling a document a thousand lines at once. A note, which
/// is typed rather than pressed, is allowed a frame's worth of fast typing.
pub const max_commands = 64;

pub const Result = struct {
    buf: [max_commands]Command = @splat(.none),
    len: usize = 0,

    pub fn items(r: *const Result) []const Command {
        return r.buf[0..r.len];
    }

    fn push(r: *Result, c: Command) void {
        if (r.len == r.buf.len) return;
        r.buf[r.len] = c;
        r.len += 1;
    }
};

/// One key as a binding names it: a character, and whether ctrl or alt was
/// held. The same shape as `thviti.input.Chord`, which is what it is matched
/// against.
pub const Key = struct {
    char: u21,
    ctrl: bool = false,
    alt: bool = false,
};

/// Where the keymap asks whether a plugin has bound a key, before it looks at
/// its own bindings -- so a plugin can take any key, `<C-w>` included, the
/// way a mapping in `init.lua` overrides Neovim's defaults.
///
/// An interface and not an import, because the keymap is Hliðskjálf's and the
/// plugins are Galdr's, and neither should have to know the other exists.
pub const Lookup = struct {
    ptr: *anyopaque,
    find: *const fn (ptr: *anyopaque, mode: Mode, key: Key) ?u32,

    fn get(l: ?Lookup, mode: Mode, key: Key) ?u32 {
        const lookup = l orelse return null;
        return lookup.find(lookup.ptr, mode, key);
    }
};

/// Turns one frame's input into commands, in the order the keys arrived.
pub fn command(state: *State, in: Input) Result {
    return commandWith(state, in, null);
}

/// The same, consulting plugin bindings first.
pub fn commandWith(state: *State, in: Input, plugins: ?Lookup) Result {
    var out: Result = .{};

    if (state.mode == .note or state.mode == .command) {
        typingKeys(state, in, &out);
        return out;
    }

    // Chords a plugin has bound, before the built-in ones: a binding for
    // `<C-w>` replaces the window prefix rather than competing with it.
    var claimed_ctrl_w = false;
    var claimed_ctrl_r = false;
    var claimed_ctrl_p = false;
    if (state.pending == .none) {
        for (in.events) |e| switch (e) {
            .key_down => |k| {
                if (k.repeat or k.char == 0 or !(k.modifiers.ctrl or k.modifiers.alt)) continue;
                const key: Key = .{ .char = lowerAscii(k.char), .ctrl = k.modifiers.ctrl, .alt = k.modifiers.alt };
                const id = Lookup.get(plugins, state.mode, key) orelse continue;
                out.push(.{ .plugin_key = id });
                if (key.ctrl and !key.alt and key.char == 'w') claimed_ctrl_w = true;
                if (key.ctrl and !key.alt and key.char == 'r') claimed_ctrl_r = true;
                if (key.ctrl and !key.alt and key.char == 'p') claimed_ctrl_p = true;
            },
            else => {},
        };
    }

    // The prefix first, and its expiry: a `<C-w>` left pending from two
    // minutes ago must not turn the next `v` into a split.
    if (state.pending != .none) {
        state.waited += in.dt;
        if (state.waited > prefix_timeout) state.pending = .none;
    }
    // Only the window prefix is finished here. `g` is a letter and its second
    // key is one too, so it is completed down in the loop over the frame's
    // text -- where the codepoint still has its case and `gt` and `gT` are
    // two different keys.
    if (state.pending == .window) {
        if (windowKey(in)) |c| {
            state.pending = .none;
            out.push(c);
            return out;
        }
        if (in.pressedOnce(.escape)) {
            state.pending = .none;
            return out;
        }
        // Anything else is swallowed: half a window command is not a scroll.
        if (in.events.len != 0) state.pending = .none;
        if (state.pending == .window) return out;
    }

    if (state.mode == .normal and !claimed_ctrl_w and in.chorded(.ctrlKey('w'))) {
        state.pending = .window;
        state.waited = 0;
        return out;
    }
    if (!claimed_ctrl_r and in.chorded(.ctrlKey('r'))) out.push(.redo);
    if (!claimed_ctrl_p and in.chorded(.ctrlKey('p'))) out.push(.show_commands);

    // The wheel scrolls in every mode: reading on while a selection is held
    // is how a selection longer than a screen gets made.
    if (in.modifiers.ctrl and in.scroll.y != 0) {
        out.push(.{ .zoom_by = std.math.pow(f32, 1.0015, in.scroll.y) });
    } else if (in.scroll.y != 0) {
        out.push(.{ .scroll_pixels = -in.scroll.y });
    }

    if (in.repeated(.page_down)) out.push(.{ .scroll_screens = 1 });
    if (in.repeated(.page_up)) out.push(.{ .scroll_screens = -1 });
    if (in.pressedOnce(.home)) out.push(.to_start);
    if (in.pressedOnce(.end)) out.push(.to_end);

    switch (state.mode) {
        .edit => {
            if (in.repeated(.down) or in.pressedOnce(.tab)) out.push(.next_mark);
            if (in.repeated(.up)) out.push(.previous_mark);
            if (in.pressedOnce(.delete)) out.push(.delete_mark);
            if (in.pressedOnce(.enter)) {
                state.mode = .note;
                out.push(.enter_note);
            }
        },
        else => {
            if (in.repeated(.down)) out.push(.{ .move_cursor = .down });
            if (in.repeated(.up)) out.push(.{ .move_cursor = .up });
            if (in.repeated(.right)) out.push(.{ .move_cursor = .right });
            if (in.repeated(.left)) out.push(.{ .move_cursor = .left });
            if (state.mode.isVisual() and in.pressedOnce(.enter)) {
                state.mode = .normal;
                out.push(.{ .highlight_selection = null });
            }
        },
    }

    if (in.pressedOnce(.escape)) {
        // A half-typed `g` goes first, so escape abandons the prefix rather
        // than the cursor somebody was about to move with it.
        if (state.pending == .g) {
            state.pending = .none;
        } else if (state.mode == .normal) {
            out.push(.hide_cursor);
        } else {
            state.mode = .normal;
            out.push(.leave_mode);
        }
    }

    // The mode as the text begins. A note entered by the enter key above was
    // entered before any text, and that enter must not also commit it.
    const before_text = state.mode;
    var buf: [256]u8 = undefined;
    const typed = in.typedText(&buf);
    var it = (std.unicode.Utf8View.init(typed) catch return out).iterator();
    while (it.nextCodepoint()) |c| {
        // Mode changes take effect for the very next key, so a note or a
        // command begun and typed within one frame gets its text.
        if (state.mode == .note) {
            if (c >= 0x20 and c != 0x7f) out.push(.{ .note_char = c });
            continue;
        }
        if (state.mode == .command) {
            if (c >= 0x20 and c != 0x7f) out.push(.{ .command_char = c });
            continue;
        }
        // The key after `g`, before anything else can claim it: a tabpage
        // command is `g` and one letter, and that letter is not a motion.
        if (state.pending == .g) {
            state.pending = .none;
            if (tabKey(c)) |cmd| out.push(cmd);
            continue;
        }
        if (Lookup.get(plugins, state.mode, .{ .char = c })) |id| {
            out.push(.{ .plugin_key = id });
            continue;
        }
        switch (state.mode) {
            .normal => normalKey(state, c, &out),
            .visual, .visual_line => visualKey(state, c, &out),
            .edit => editKey(state, c, &out),
            .draw => drawKey(state, c, &out),
            .note, .command => unreachable,
        }
    }
    // Enter or backspace in the same frame as the keys that began a command
    // or a note: handled after the text, so `:q` and enter typed together
    // still run `q`.
    const typing_now = state.mode == .note or state.mode == .command;
    const typing_before = before_text == .note or before_text == .command;
    if (typing_now and !typing_before) typingEnd(state, in, &out);
    return out;
}

/// Case folding for chords, matching `thviti.input`.
fn lowerAscii(c: u21) u21 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// A motion, the same in normal and visual mode.
fn motion(c: u21) ?View.Step {
    return switch (c) {
        'j' => .down,
        'k' => .up,
        'h' => .left,
        'l' => .right,
        '^' => .line_start,
        '$' => .line_end,
        'w' => .word_next,
        'b' => .word_previous,
        'e' => .word_end,
        else => null,
    };
}

fn digit(c: u21) ?u8 {
    if (c < '1' or c > '0' + palette_size) return null;
    return @intCast(c - '1');
}

/// What picking palette colour `index` does in `mode`, or null where the mode
/// has no use for a colour.
///
/// Public because the digits are not the only way to reach one: the left rail
/// draws the palette as swatches, and a swatch that meant something different
/// from the digit printed in its tooltip would be a bug nobody could see. One
/// table, two ways in.
pub fn paletteCommand(mode: Mode, index: u8) ?Command {
    if (index >= palette_size) return null;
    return switch (mode) {
        .visual, .visual_line => .{ .highlight_selection = index },
        .edit, .note => .{ .recolour_mark = index },
        // Not a mark being recoloured: the pen is, and the next stroke comes
        // out in it. The swatch a digit points at is the same either way,
        // which is the whole reason this table is one table.
        .draw => .{ .pen_colour = index },
        .normal, .command => null,
    };
}

/// Enters a mode from something that is not a key -- a rail button, a menu
/// row -- and returns the command the keymap would have pushed beside it.
///
/// The mode change and the command are one act and they are here together for
/// that reason: `v` sets `state.mode` and pushes `.enter_visual`, and a
/// caller that did one without the other would leave the reader in a mode
/// nothing had prepared.
pub fn enter(state: *State, mode: Mode) Command {
    state.mode = mode;
    return switch (mode) {
        .normal => .leave_mode,
        .visual => .enter_visual,
        .visual_line => .enter_visual_line,
        .edit => .enter_edit,
        .draw => .enter_draw,
        .note => .enter_note,
        .command => .enter_command,
    };
}

fn normalKey(state: *State, c: u21, out: *Result) void {
    if (motion(c)) |step| return out.push(.{ .move_cursor = step });
    const cmd: Command = switch (c) {
        'q' => .quit,
        'Q' => .quit_all,
        ' ' => .next_page,
        'n' => .{ .search_step = false },
        'N' => .{ .search_step = true },
        'p' => .previous_page,
        '/' => .enter_search,
        'm' => .toggle_highlight,
        'M' => .clear_highlights,
        'u' => .undo,
        '+', '=' => .{ .zoom_by = 1.25 },
        '-', '_' => .{ .zoom_by = 1.0 / 1.25 },
        '0' => .{ .fit = .width },
        '1' => .{ .zoom_to = 1 },
        'v' => blk: {
            state.mode = .visual;
            break :blk .enter_visual;
        },
        'V' => blk: {
            state.mode = .visual_line;
            break :blk .enter_visual_line;
        },
        'i' => blk: {
            state.mode = .edit;
            break :blk .enter_edit;
        },
        'd' => blk: {
            state.mode = .draw;
            break :blk .enter_draw;
        },
        ':' => blk: {
            state.mode = .command;
            break :blk .enter_command;
        },
        'g' => {
            state.pending = .g;
            state.waited = 0;
            return;
        },
        else => return,
    };
    out.push(cmd);
}

fn visualKey(state: *State, c: u21, out: *Result) void {
    if (motion(c)) |step| return out.push(.{ .move_cursor = step });
    if (digit(c)) |d| {
        // The mode ends on a colour: the highlight is made and there is
        // nothing selected any more.
        const cmd = paletteCommand(state.mode, d) orelse return;
        state.mode = .normal;
        return out.push(cmd);
    }
    const cmd: Command = switch (c) {
        'o' => .swap_selection_ends,
        'm', 'y' => blk: {
            state.mode = .normal;
            break :blk .{ .highlight_selection = null };
        },
        'd', 'x' => blk: {
            state.mode = .normal;
            break :blk .unhighlight_selection;
        },
        'u' => .undo,
        // The same key again leaves; the other visual key switches kind, as
        // `v` and `V` do in Vim.
        'v' => blk: {
            if (state.mode == .visual) {
                state.mode = .normal;
                break :blk .leave_mode;
            }
            state.mode = .visual;
            break :blk .enter_visual;
        },
        'V' => blk: {
            if (state.mode == .visual_line) {
                state.mode = .normal;
                break :blk .leave_mode;
            }
            state.mode = .visual_line;
            break :blk .enter_visual_line;
        },
        else => return,
    };
    out.push(cmd);
}

fn editKey(state: *State, c: u21, out: *Result) void {
    if (digit(c)) |d| {
        if (paletteCommand(state.mode, d)) |cmd| return out.push(cmd);
        return;
    }
    const cmd: Command = switch (c) {
        'n', 'j' => .next_mark,
        'N', 'k' => .previous_mark,
        'd', 'x' => .delete_mark,
        'u' => .undo,
        'a', 'i', 'A' => blk: {
            state.mode = .note;
            break :blk .enter_note;
        },
        'q' => blk: {
            state.mode = .normal;
            break :blk .leave_mode;
        },
        else => return,
    };
    out.push(cmd);
}

/// Draw mode, where the keyboard's job is to set the pen down and get out of
/// the way: a colour, a width, undo, and how to leave.
///
/// No motions. The hand that is drawing is on the pointer, and `j` under it
/// would be a key nobody could reach without stopping -- so the letters that
/// are motions everywhere else are left unbound rather than given a second
/// meaning here.
fn drawKey(state: *State, c: u21, out: *Result) void {
    if (digit(c)) |d| {
        if (paletteCommand(state.mode, d)) |cmd| return out.push(cmd);
        return;
    }
    const cmd: Command = switch (c) {
        // A factor, not a step: three presses of `]` take a hairline to a
        // marker pen and three of `[` bring it back to exactly where it was.
        '[' => .{ .pen_width = 1.0 / 1.4 },
        ']' => .{ .pen_width = 1.4 },
        'u' => .undo,
        // The same key again leaves, as `v` does in visual mode. `q` too,
        // because that is how edit mode is left and a reader should not have
        // to remember which of the two they are in to get out.
        'd', 'q' => blk: {
            state.mode = .normal;
            break :blk .leave_mode;
        },
        else => return,
    };
    out.push(cmd);
}

/// A frame in which text is being typed: a note, or the command line.
fn typingKeys(state: *State, in: Input, out: *Result) void {
    const note = state.mode == .note;
    if (in.pressedOnce(.escape)) {
        // Escape abandons what was typed. A note returns to edit rather than
        // normal, since the highlight being annotated is still in hand.
        state.mode = if (note) .edit else .normal;
        out.push(.leave_mode);
        return;
    }
    // Text first, then the keys that end it, so that a word and its enter in
    // one frame keep the word.
    var buf: [256]u8 = undefined;
    const typed = in.typedText(&buf);
    if (std.unicode.Utf8View.init(typed)) |view| {
        var it = view.iterator();
        while (it.nextCodepoint()) |c| {
            if (c < 0x20 or c == 0x7f) continue;
            out.push(if (note) .{ .note_char = c } else .{ .command_char = c });
        }
    } else |_| {}
    typingEnd(state, in, out);
}

fn typingEnd(state: *State, in: Input, out: *Result) void {
    const note = state.mode == .note;
    for (in.events) |e| switch (e) {
        .key_down => |k| if (k.code == .backspace) out.push(if (note) .note_backspace else .command_backspace),
        else => {},
    };
    if (in.pressedOnce(.enter)) {
        state.mode = if (note) .edit else .normal;
        out.push(if (note) .note_commit else .command_run);
    }
}

/// The key after `<C-w>`.
///
/// Read from the key event's character rather than from typed text: the
/// prefix is held with ctrl on some keyboards and released on others, and a
/// binding that worked only when the finger came off the modifier in time
/// would be maddening.
fn windowKey(in: Input) ?Command {
    const pairs = .{
        .{ 's', Command{ .split = .horizontal } },
        .{ 'v', Command{ .split = .vertical } },
        .{ 'c', Command.close_window },
        .{ 'q', Command.close_window },
        .{ 'o', Command.only_window },
        .{ 'w', Command{ .cycle_window = false } },
        .{ 'W', Command{ .cycle_window = true } },
        .{ 'h', Command{ .focus_side = .left } },
        .{ 'j', Command{ .focus_side = .down } },
        .{ 'k', Command{ .focus_side = .up } },
        .{ 'l', Command{ .focus_side = .right } },
        .{ '=', Command.equalise },
        .{ 'n', Command.next_buffer },
        .{ 'b', Command.previous_buffer },
        .{ 'T', Command.window_to_tab },
    };
    inline for (pairs) |p| {
        if (in.typedKey(p[0])) return p[1];
    }
    return null;
}

/// The key after `g`.
///
/// Read from the codepoint rather than from a key event, because `gt` and
/// `gT` differ only in their case and `Input.typedKey` folds it -- deliberately,
/// since a layout that reports `W` for the `w` key should still answer to
/// `<C-w>w`. What is right for a chord is wrong for a letter.
fn tabKey(c: u21) ?Command {
    return switch (c) {
        't' => .{ .go_tab = 1 },
        'T' => .{ .go_tab = -1 },
        else => null,
    };
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;
const Event = thviti.input.Event;

fn press(char: u21, ctrl: bool) Event {
    return .{ .key_down = .{
        .code = .other,
        .char = char,
        .modifiers = .{ .ctrl = ctrl },
    } };
}

fn keyDown(code: thviti.input.KeyCode) Event {
    return .{ .key_down = .{ .code = code } };
}

fn frame(events: []const Event) Input {
    return .{ .events = events, .modifiers = if (events.len != 0) switch (events[0]) {
        .key_down => |k| k.modifiers,
        else => .{},
    } else .{} };
}

fn typing(s: []const u8) Input {
    const Static = struct {
        var ev: [1]Event = undefined;
    };
    Static.ev[0] = .{ .text = s };
    return .{ .events = &Static.ev };
}

test "a bare key is a reader command" {
    var state: State = .{};
    const out = command(&state, typing("j"));
    try testing.expectEqual(@as(usize, 1), out.items().len);
    try testing.expectEqual(View.Step.down, out.items()[0].move_cursor);
}

test "word motions are motions in normal and visual mode" {
    var state: State = .{};
    const out = command(&state, typing("wbe"));
    try testing.expectEqual(View.Step.word_next, out.items()[0].move_cursor);
    try testing.expectEqual(View.Step.word_previous, out.items()[1].move_cursor);
    try testing.expectEqual(View.Step.word_end, out.items()[2].move_cursor);

    state.mode = .visual;
    const again = command(&state, typing("w"));
    try testing.expectEqual(View.Step.word_next, again.items()[0].move_cursor);
}

test "v, motions and m, typed within one frame, select and highlight" {
    // Faster than a frame is how people type; the mode has to change as each
    // key is read, not once per frame.
    var state: State = .{};
    const out = command(&state, typing("vjjm"));
    try testing.expectEqual(@as(usize, 4), out.items().len);
    try testing.expectEqual(Command.enter_visual, out.items()[0]);
    try testing.expectEqual(View.Step.down, out.items()[1].move_cursor);
    try testing.expectEqual(View.Step.down, out.items()[2].move_cursor);
    try testing.expectEqual(@as(?u8, null), out.items()[3].highlight_selection);
    try testing.expectEqual(Mode.normal, state.mode);
}

test "the same key means one thing in normal mode and another in visual" {
    var state: State = .{};
    // `m` in normal mode is the line highlight...
    try testing.expectEqual(Command.toggle_highlight, command(&state, typing("m")).items()[0]);
    // ...`d` goes to the pen...
    try testing.expectEqual(Command.enter_draw, command(&state, typing("d")).items()[0]);
    try testing.expectEqual(Mode.draw, state.mode);

    // ...and in visual mode `m` highlights the selection and `d` removes.
    state.mode = .visual;
    try testing.expect(command(&state, typing("m")).items()[0] == .highlight_selection);
    state.mode = .visual;
    try testing.expectEqual(Command.unhighlight_selection, command(&state, typing("d")).items()[0]);
    try testing.expectEqual(Mode.normal, state.mode);
}

test "a digit in visual mode highlights in that colour" {
    var state: State = .{ .mode = .visual };
    const out = command(&state, typing("3"));
    try testing.expectEqual(@as(?u8, 2), out.items()[0].highlight_selection);
    try testing.expectEqual(Mode.normal, state.mode);
}

test "v in visual mode leaves, and V switches to lines" {
    var state: State = .{ .mode = .visual };
    try testing.expectEqual(Command.enter_visual_line, command(&state, typing("V")).items()[0]);
    try testing.expectEqual(Mode.visual_line, state.mode);
    try testing.expectEqual(Command.leave_mode, command(&state, typing("V")).items()[0]);
    try testing.expectEqual(Mode.normal, state.mode);
}

test "escape leaves every mode, and in normal mode puts the cursor away" {
    var state: State = .{ .mode = .edit };
    try testing.expectEqual(Command.leave_mode, command(&state, frame(&.{keyDown(.escape)})).items()[0]);
    try testing.expectEqual(Mode.normal, state.mode);
    try testing.expectEqual(Command.hide_cursor, command(&state, frame(&.{keyDown(.escape)})).items()[0]);
}

test "edit mode walks, recolours, deletes and starts a note" {
    var state: State = .{};
    try testing.expectEqual(Command.enter_edit, command(&state, typing("i")).items()[0]);
    try testing.expectEqual(Mode.edit, state.mode);

    try testing.expectEqual(Command.next_mark, command(&state, typing("n")).items()[0]);
    try testing.expectEqual(Command.previous_mark, command(&state, typing("N")).items()[0]);
    try testing.expectEqual(@as(u8, 4), command(&state, typing("5")).items()[0].recolour_mark);
    try testing.expectEqual(Command.delete_mark, command(&state, typing("d")).items()[0]);

    // `q` in edit mode leaves the mode, not the reader.
    try testing.expectEqual(Command.leave_mode, command(&state, typing("q")).items()[0]);
    try testing.expectEqual(Mode.normal, state.mode);
}

test "in a note every key is text, even the ones that are commands elsewhere" {
    var state: State = .{ .mode = .edit };
    const out = command(&state, typing("aq v"));
    try testing.expectEqual(Command.enter_note, out.items()[0]);
    try testing.expectEqual(Mode.note, state.mode);
    try testing.expectEqual(@as(u21, 'q'), out.items()[1].note_char);
    try testing.expectEqual(@as(u21, ' '), out.items()[2].note_char);
    try testing.expectEqual(@as(u21, 'v'), out.items()[3].note_char);

    // Not ASCII either, which is the point of decoding rather than taking
    // bytes.
    const accented = command(&state, typing("é"));
    try testing.expectEqual(@as(u21, 0xe9), accented.items()[0].note_char);

    // Enter keeps it and returns to edit; escape would have thrown it away.
    const done = command(&state, frame(&.{keyDown(.enter)}));
    try testing.expectEqual(Command.note_commit, done.items()[0]);
    try testing.expectEqual(Mode.edit, state.mode);

    state.mode = .note;
    const gone = command(&state, frame(&.{keyDown(.escape)}));
    try testing.expectEqual(Command.leave_mode, gone.items()[0]);
    try testing.expectEqual(Mode.edit, state.mode);
}

test "window commands are not available while selecting" {
    var state: State = .{ .mode = .visual };
    _ = command(&state, frame(&.{press('w', true)}));
    try testing.expectEqual(Prefix.none, state.pending);
}

test "u undoes in every mode that is not typing, and ctrl-r redoes" {
    for ([_]Mode{ .normal, .visual, .edit }) |mode| {
        var state: State = .{ .mode = mode };
        try testing.expectEqual(Command.undo, command(&state, typing("u")).items()[0]);
    }
    var state: State = .{};
    try testing.expectEqual(Command.redo, command(&state, frame(&.{press('r', true)})).items()[0]);

    // And in a note, `u` is a letter.
    state.mode = .note;
    try testing.expectEqual(@as(u21, 'u'), command(&state, typing("u")).items()[0].note_char);
}

test "the window prefix takes the next key and nothing else" {
    var state: State = .{};
    const armed = command(&state, frame(&.{press('w', true)}));
    try testing.expectEqual(@as(usize, 0), armed.items().len);
    try testing.expectEqual(Prefix.window, state.pending);

    const out = command(&state, frame(&.{press('v', false)}));
    try testing.expectEqual(Prefix.none, state.pending);
    try testing.expectEqual(Layout.Direction.vertical, out.items()[0].split);
    // And `v` after the prefix is a split, not visual mode.
    try testing.expectEqual(Mode.normal, state.mode);
}

test "an abandoned prefix times out rather than eating a later key" {
    var state: State = .{};
    _ = command(&state, frame(&.{press('w', true)}));
    _ = command(&state, .{ .dt = prefix_timeout + 0.1 });
    try testing.expectEqual(Prefix.none, state.pending);
}

test "every window key is bound, and to the thing vim binds it to" {
    var state: State = .{};
    const cases = .{
        .{ 's', Command{ .split = .horizontal } },
        .{ 'v', Command{ .split = .vertical } },
        .{ 'c', Command.close_window },
        .{ 'o', Command.only_window },
        .{ 'h', Command{ .focus_side = .left } },
        .{ 'l', Command{ .focus_side = .right } },
        .{ '=', Command.equalise },
    };
    inline for (cases) |c| {
        _ = command(&state, frame(&.{press('w', true)}));
        const out = command(&state, frame(&.{press(c[0], false)}));
        try testing.expectEqual(@as(usize, 1), out.items().len);
        try testing.expectEqualDeep(c[1], out.items()[0]);
    }
}

test "gt and gT are two keys apart, which is why they are read as codepoints" {
    var state: State = .{};
    const armed = command(&state, typing("g"));
    try testing.expectEqual(@as(usize, 0), armed.items().len);
    try testing.expectEqual(Prefix.g, state.pending);

    try testing.expectEqual(@as(i32, 1), command(&state, typing("t")).items()[0].go_tab);
    try testing.expectEqual(Prefix.none, state.pending);

    _ = command(&state, typing("g"));
    try testing.expectEqual(@as(i32, -1), command(&state, typing("T")).items()[0].go_tab);
}

test "a whole tabpage command typed inside one frame still means one thing" {
    var state: State = .{};
    // `g` and `T` in the same frame: the prefix is completed in the loop over
    // the text, so `T` is never looked up as a key of its own.
    const out = command(&state, typing("gT"));
    try testing.expectEqual(@as(usize, 1), out.items().len);
    try testing.expectEqual(@as(i32, -1), out.items()[0].go_tab);
    try testing.expectEqual(Prefix.none, state.pending);

    // And a letter `g` has no meaning after does nothing at all, rather than
    // falling through to whatever that letter means on its own.
    try testing.expectEqual(@as(usize, 0), command(&state, typing("gv")).items().len);
    try testing.expectEqual(Mode.normal, state.mode);
}

test "an abandoned g is escaped away without also hiding the cursor" {
    var state: State = .{};
    _ = command(&state, typing("g"));
    const out = command(&state, frame(&.{keyDown(.escape)}));
    try testing.expectEqual(Prefix.none, state.pending);
    try testing.expectEqual(@as(usize, 0), out.items().len);

    // Escape with nothing pending is the cursor again, as it always was.
    try testing.expectEqual(Command.hide_cursor, command(&state, frame(&.{keyDown(.escape)})).items()[0]);
}

test "ctrl-w T moves the window to a tabpage of its own" {
    var state: State = .{};
    _ = command(&state, frame(&.{press('w', true)}));
    const out = command(&state, frame(&.{press('T', false)}));
    try testing.expectEqual(Command.window_to_tab, out.items()[0]);
}

test "ctrl and the wheel is a zoom, and the wheel alone is a scroll" {
    var state: State = .{};
    const zoom = command(&state, .{ .scroll = .{ .x = 0, .y = 120 }, .modifiers = .{ .ctrl = true } });
    try testing.expect(zoom.items()[0].zoom_by > 1);
    const scroll = command(&state, .{ .scroll = .{ .x = 0, .y = 120 } });
    try testing.expect(scroll.items()[0].scroll_pixels < 0);
}

test "a frame of nothing produces no commands" {
    var state: State = .{};
    try testing.expectEqual(@as(usize, 0), command(&state, .{}).items().len);
}

test "colon opens the command line, and enter runs what was typed" {
    var state: State = .{};
    const out = command(&state, typing(":q"));
    try testing.expectEqual(Command.enter_command, out.items()[0]);
    try testing.expectEqual(@as(u21, 'q'), out.items()[1].command_char);
    try testing.expectEqual(Mode.command, state.mode);

    // `q` on the command line is text, not quit.
    const more = command(&state, typing("a"));
    try testing.expectEqual(@as(u21, 'a'), more.items()[0].command_char);

    const run = command(&state, frame(&.{keyDown(.enter)}));
    try testing.expectEqual(Command.command_run, run.items()[0]);
    try testing.expectEqual(Mode.normal, state.mode);

    state.mode = .command;
    const gone = command(&state, frame(&.{keyDown(.escape)}));
    try testing.expectEqual(Command.leave_mode, gone.items()[0]);
    try testing.expectEqual(Mode.normal, state.mode);
}

test "enter in edit mode starts a note and does not also commit it" {
    var state: State = .{ .mode = .edit };
    const out = command(&state, frame(&.{keyDown(.enter)}));
    try testing.expectEqual(@as(usize, 1), out.items().len);
    try testing.expectEqual(Command.enter_note, out.items()[0]);
    try testing.expectEqual(Mode.note, state.mode);
}

const TestBindings = struct {
    fn find(_: *anyopaque, mode: Mode, k: Key) ?u32 {
        if (mode == .normal and k.char == 'j' and !k.ctrl) return 7;
        if (mode == .normal and k.char == 'w' and k.ctrl) return 9;
        return null;
    }
};

test "a plugin binding takes a key before the built-in one" {
    var dummy: u8 = 0;
    const lookup: Lookup = .{ .ptr = &dummy, .find = TestBindings.find };
    var state: State = .{};

    // `j` is the plugin's in normal mode...
    const out = commandWith(&state, typing("jk"), lookup);
    try testing.expectEqual(@as(u32, 7), out.items()[0].plugin_key);
    // ...and `k`, which it did not bind, is still the built-in.
    try testing.expectEqual(View.Step.up, out.items()[1].move_cursor);

    // In visual mode the binding does not apply.
    state.mode = .visual;
    const visual = commandWith(&state, typing("j"), lookup);
    try testing.expectEqual(View.Step.down, visual.items()[0].move_cursor);

    // A plugin that binds `<C-w>` replaces the window prefix.
    state.mode = .normal;
    const chord = commandWith(&state, frame(&.{press('w', true)}), lookup);
    try testing.expectEqual(@as(u32, 9), chord.items()[0].plugin_key);
    try testing.expectEqual(Prefix.none, state.pending);

    // And on the command line, nothing is a binding.
    state.mode = .command;
    const typed_j = commandWith(&state, typing("j"), lookup);
    try testing.expectEqual(@as(u21, 'j'), typed_j.items()[0].command_char);
}

test "slash opens a search, and n and N step it while space still turns the page" {
    var state: State = .{};
    const out = command(&state, typing("/"));
    try testing.expectEqual(Command.enter_search, out.items()[0]);
    // `/` does not change the mode: the search bar is a widget and takes the
    // keyboard by having focus, not by the keymap standing aside.
    try testing.expectEqual(Mode.normal, state.mode);

    const stepping = command(&state, typing("nN "));
    try testing.expectEqual(false, stepping.items()[0].search_step);
    try testing.expectEqual(true, stepping.items()[1].search_step);
    // The page keys never go anywhere, which is what lets `n` mean two
    // things without anybody losing one of them.
    try testing.expectEqual(Command.next_page, stepping.items()[2]);
    try testing.expectEqual(Command.previous_page, command(&state, typing("p")).items()[0]);
}

test "draw mode is entered by d, left by d, q or escape, and takes the digits" {
    var state: State = .{};
    try testing.expectEqual(Command.enter_draw, command(&state, typing("d")).items()[0]);
    try testing.expectEqual(Mode.draw, state.mode);

    // A digit picks the pen's colour rather than recolouring anything, and
    // it is the same index it would be in any other mode.
    try testing.expectEqual(@as(u8, 2), command(&state, typing("3")).items()[0].pen_colour);
    try testing.expectEqual(Mode.draw, state.mode);

    // The width compounds: `]` three times and `[` three times is where it
    // started, which is what makes it a factor rather than a step.
    const wider = command(&state, typing("]")).items()[0].pen_width;
    const thinner = command(&state, typing("[")).items()[0].pen_width;
    try testing.expectApproxEqAbs(@as(f32, 1), wider * thinner, 0.0001);

    // Undo works here, as it does everywhere but the two typing modes.
    try testing.expectEqual(Command.undo, command(&state, typing("u")).items()[0]);

    try testing.expectEqual(Command.leave_mode, command(&state, typing("d")).items()[0]);
    try testing.expectEqual(Mode.normal, state.mode);

    state.mode = .draw;
    try testing.expectEqual(Command.leave_mode, command(&state, typing("q")).items()[0]);
    try testing.expectEqual(Mode.normal, state.mode);

    state.mode = .draw;
    _ = command(&state, frame(&.{keyDown(.escape)}));
    try testing.expectEqual(Mode.normal, state.mode);
}

test "draw mode binds no motions, because the hand that is drawing is not on the keyboard" {
    var state: State = .{ .mode = .draw };
    // Every letter that is a motion in normal and visual mode.
    for ("hjklwbe^$") |c| {
        const out = command(&state, typing(&[_]u8{c}));
        try testing.expectEqual(@as(usize, 0), out.items().len);
        try testing.expectEqual(Mode.draw, state.mode);
    }
}
