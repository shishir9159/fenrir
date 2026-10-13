//! The command palette: everything the reader can do, filtered as you type.
//!
//! The `:` line has been the only way to reach a command since it was
//! written, and it answers no question. You have to know a command exists
//! before you can type it, and know how it is spelled before you can finish
//! it. `hlidskjalf/commands.zig` made the list enumerable; this is the list.
//!
//! ## What this file knows, and what it does not
//!
//! A `Row` is a name, a sentence, a binding and an icon name. Not an `Id`,
//! not a `Session`, and nothing that can be run: the palette reports the row
//! that was chosen and the reader runs it, which is the same division
//! `panels.zig` draws for a panel row and `settings.zig` for a setting. So
//! the matcher and the ranking are asked about in a test with no window, no
//! device and no document -- and `fenrir commands --match` asks the same
//! question from a terminal.
//!
//! It also means a plugin's command is a `Row` like any other. The reader
//! fills the array from the built-in table and from `Runtime.commandNames()`,
//! and nothing here can tell which is which.
//!
//! ## The matcher, and why the two halves are matched differently
//!
//! A name is matched as a **subsequence**: `tn` finds `tabnew`, `cw` finds
//! `close` before it finds anything else, which is how every palette worth
//! using behaves. A description is matched as a **substring**: typing
//! `window` should find the three commands that say "window" in their
//! sentence, and subsequence-matching a sentence matches nearly every
//! sentence -- `ce` alone would hit twenty of twenty-five. Precision where
//! the text is long, and forgiveness where it is short.
//!
//! ## Ranking is done on a change, not on a frame
//!
//! The order is recomputed when the query changes, when the rows change, and
//! when the palette opens -- and never otherwise, because a palette sitting
//! open with nobody typing must cost what every other settled interface in
//! this program costs, which is nothing. The ranked indices live in a fixed
//! array on the state, so none of it allocates either.

const std = @import("std");
const fenrir = @import("fenrir");

const thviti = fenrir.thviti;

const commands = fenrir.hlidskjalf.commands;
const w = thviti.widgets;

/// The longest query worth keeping. A command name and its argument; a person
/// typing more than this wants the `:` line, which is still there.
pub const query_max = 96;

/// The most rows the palette will rank. Twenty-five built-ins and room for a
/// configuration full of plugin commands.
pub const max_rows = 256;

/// One command, as the palette shows it.
pub const Row = struct {
    /// What is typed after `:`, and what the reader runs.
    name: []const u8,
    /// The abbreviations it also answers to. Matched like the name and shown
    /// after it, because an abbreviation somebody cannot see is one they
    /// never learn.
    aliases: []const []const u8 = &.{},
    /// One line, in the words `fenrir commands` prints.
    about: []const u8 = "",
    /// The keys that reach the same thing without any of this. Drawn at the
    /// right-hand end: the design language says a command's binding is drawn
    /// beside it, and this is the one list where every command has a place
    /// to put one.
    binding: []const u8 = "",
    /// A registered icon name, or empty for no picture.
    icon: []const u8 = "",
    /// Choosing it puts the name on the `:` line rather than running it,
    /// because `:page` with nothing after it is a mistake.
    needs_argument: bool = false,
};

/// The built-in commands as rows, in the table's order.
///
/// Fills a caller's slice rather than returning one, because the array is
/// the caller's: the reader appends whatever the plugins registered after
/// these, and the palette can then not tell the two apart.
pub fn builtins(out: []Row) []Row {
    const n = @min(out.len, commands.table.len);
    for (commands.table[0..n], out[0..n]) |e, *row| row.* = .{
        .name = e.name,
        .aliases = e.aliases,
        .about = e.about,
        .binding = e.binding,
        .icon = e.icon,
        .needs_argument = e.needs_argument,
    };
    return out[0..n];
}

/// What the palette was asked for. Both borrow bytes that outlive the frame:
/// a row's from the caller's array, a line's from the state's own buffer.
pub const Chosen = union(enum) {
    row: Row,
    /// Enter with nothing matching what was typed: the line itself, to be run
    /// as though it had been typed after `:`. What keeps the palette a
    /// superset of the command line rather than a friendlier half of it.
    line: []const u8,
};

pub const State = struct {
    open: bool = false,

    /// The query. `bytes` is an interior pointer into `query_buf` and is
    /// re-aimed at it every frame, so this struct survives being copied --
    /// which it has to, since a `Session` is returned by value in the tests.
    field: w.Field = .{ .bytes = &.{} },
    query_buf: [query_max]u8 = undefined,
    /// The field has just appeared and wants the keyboard. A control that
    /// appears already wanting it has to ask.
    focus_next: bool = false,

    /// The rows that matched, best first, by their index in the caller's
    /// array.
    order: [max_rows]u16 = @splat(0),
    shown: u16 = 0,
    /// Which of `order` is highlighted. Always a valid index while `shown`
    /// is not zero, which `rank` guarantees by clamping it.
    at: u16 = 0,

    /// The ranking is out of date: the query changed, the rows changed, or
    /// the palette has just opened.
    dirty: bool = true,
    /// The highlighted row should be brought into view -- set when a key
    /// moved it, because the list is the only thing that knows where its rows
    /// are.
    reveal: bool = false,

    pub fn show(st: *State) void {
        st.open = true;
        st.dirty = true;
        st.at = 0;
        st.focus_next = true;
        st.field.bytes = &st.query_buf;
        st.field.clear();
    }

    pub fn hide(st: *State) void {
        st.open = false;
    }

    pub fn query(st: *const State) []const u8 {
        return st.field.slice();
    }

    /// The row the keyboard is on, or null when nothing matched.
    pub fn selected(st: *const State, rows: []const Row) ?Row {
        if (st.shown == 0 or st.at >= st.shown) return null;
        return rows[st.order[st.at]];
    }

    /// Re-ranks against `rows`. Called when something changed; see the note
    /// at the top about why not per frame.
    pub fn rerank(st: *State, rows: []const Row) void {
        st.dirty = false;
        st.shown = rank(st.query(), rows, &st.order);
        if (st.at >= st.shown) st.at = if (st.shown == 0) 0 else st.shown - 1;
    }

    fn step(st: *State, delta: i32) void {
        if (st.shown == 0) return;
        const n: i32 = @intCast(st.shown);
        const to = @mod(@as(i32, @intCast(st.at)) + delta + n, n);
        st.at = @intCast(to);
        st.reveal = true;
    }
};

// -- the matcher ---------------------------------------------------------------

/// Where one word ends and the next begins, for the bonus below.
fn isBreak(c: u8) bool {
    return c == ' ' or c == '_' or c == '-' or c == '.' or c == ':';
}

/// How well `query` matches `text` as a subsequence, or null for no match.
/// Higher is better; the numbers mean nothing on their own and only ever get
/// compared with each other.
///
/// Four things are worth points, in the order somebody typing expects them:
/// a run of letters next to each other, a letter that starts a word, a short
/// answer over a long one, and a match that did not have to skip far to be
/// found.
pub fn score(query: []const u8, text: []const u8) ?i32 {
    if (query.len > text.len) return null;

    var total: i32 = 0;
    var run: i32 = 0;
    var at: usize = 0;
    var last: ?usize = null;

    for (query) |q| {
        const want = std.ascii.toLower(q);
        const hit = while (at < text.len) : (at += 1) {
            if (std.ascii.toLower(text[at]) == want) break at;
        } else return null;

        run = if (last != null and hit == last.? + 1) run + 1 else 0;
        const boundary = hit == 0 or isBreak(text[hit - 1]);
        total += 1 + run * 5 + @as(i32, if (boundary) 7 else 0);
        // Having to skip is worse than not having to, up to a point: a match
        // at the end of a long name is still a match.
        total -= @intCast(@min(hit - at, 6));

        at = hit + 1;
        last = hit;
    }

    // The same query matching two names: the shorter one is what was meant.
    total -= @intCast(@min(text.len, 60) / 4);
    // Typed from the beginning, which is how a name is usually reached.
    if (std.ascii.startsWithIgnoreCase(text, query)) total += 20;
    if (query.len == text.len) total += 20;
    return total;
}

/// The best of a row's own words, or null when none of them matched.
pub fn scoreRow(query: []const u8, r: Row) ?i32 {
    if (query.len == 0) return 0;

    var best: ?i32 = score(query, r.name);
    for (r.aliases) |a| {
        // An abbreviation under its own name: `sp` should find `:split`, and
        // should not outrank a command actually called `sp`.
        if (score(query, a)) |s| {
            if (best == null or s - 6 > best.?) best = s - 6;
        }
    }
    // A substring and not a subsequence: see the note at the top.
    if (best == null and std.ascii.indexOfIgnoreCase(r.about, query) != null) best = -60;
    return best;
}

/// Fills `out` with the indices of the rows that matched, best first, and
/// returns how many. Stable: rows that score the same stay in the order they
/// were given, which is the order the table is written in.
pub fn rank(query: []const u8, rows: []const Row, out: []u16) u16 {
    const Scored = struct {
        index: u16,
        score: i32,

        fn better(_: void, a: @This(), b: @This()) bool {
            return a.score > b.score;
        }
    };

    var scored: [max_rows]Scored = undefined;
    var n: usize = 0;
    for (rows, 0..) |r, i| {
        if (n == scored.len or i > std.math.maxInt(u16)) break;
        const s = scoreRow(query, r) orelse continue;
        scored[n] = .{ .index = @intCast(i), .score = s };
        n += 1;
    }

    std.sort.insertion(Scored, scored[0..n], {}, Scored.better);

    const take = @min(n, out.len);
    for (scored[0..take], 0..) |s, i| out[i] = s.index;
    return @intCast(take);
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

/// The real table, which is what the ranking has to be good over -- a matcher
/// tuned against four invented rows is a matcher tuned against nothing.
fn table() []Row {
    const Static = struct {
        var rows: [max_rows]Row = undefined;
    };
    return builtins(&Static.rows);
}

/// Where `name` came in the ranking for `query`, or null if it did not.
fn placeOf(query: []const u8, name: []const u8) ?u16 {
    const rows = table();
    var order: [max_rows]u16 = undefined;
    const n = rank(query, rows, &order);
    for (order[0..n], 0..) |index, place| {
        if (std.mem.eql(u8, rows[index].name, name)) return @intCast(place);
    }
    return null;
}

test "a query longer than the text cannot match it" {
    try testing.expect(score("quitting", "quit") == null);
    try testing.expect(score("xyz", "") == null);
}

test "letters out of order do not match" {
    try testing.expect(score("tiuq", "quit") == null);
    try testing.expect(score("qq", "quit") == null);
}

test "case is ignored in both directions" {
    try testing.expect(score("QUIT", "quit") != null);
    try testing.expect(score("qt", "QUIT") != null);
}

test "exact beats a prefix, and a prefix beats a subsequence" {
    const exact = score("fit", "fit").?;
    const prefix = score("fit", "fit_width").?;
    const scattered = score("fit", "first thing").?;
    try testing.expect(exact > prefix);
    try testing.expect(prefix > scattered);
}

test "a run of letters beats the same letters scattered" {
    try testing.expect(score("tab", "tabnew").? > score("tab", "the about bar").?);
}

test "the shorter of two names matched the same way wins" {
    try testing.expect(score("tab", "tabnew").? > score("tab", "tabprevious").?);
}

test "the first letter of a word is worth finding" {
    // `sw` as somebody would type it for "split the window".
    try testing.expect(score("sw", "split window").? > score("sw", "slow").?);
}

test "typing a command's name puts it first" {
    try testing.expectEqual(@as(?u16, 0), placeOf("quit", "quit"));
    try testing.expectEqual(@as(?u16, 0), placeOf("tabnew", "tabnew"));
    try testing.expectEqual(@as(?u16, 0), placeOf("settings", "settings"));
    try testing.expectEqual(@as(?u16, 0), placeOf("echo", "echo"));
}

test "an abbreviation finds the command it abbreviates" {
    try testing.expectEqual(@as(?u16, 0), placeOf("sp", "split"));
    try testing.expectEqual(@as(?u16, 0), placeOf("bn", "bnext"));
    // And a name still outranks somebody else's abbreviation.
    try testing.expect(placeOf("vs", "vsplit").? == 0);
}

test "a word in the description finds the commands that say it" {
    // `split` has no "window" in its name; its sentence has one.
    try testing.expect(placeOf("window", "split") != null);
    try testing.expect(placeOf("highlights", "marks") != null);
}

test "a name match comes before a description match" {
    // `:page` against the five tabpage commands, which only say "page".
    try testing.expectEqual(@as(?u16, 0), placeOf("page", "page"));
    try testing.expect(placeOf("page", "tabnew").? > 0);
}

test "an empty query shows every command, in the table's order" {
    const rows = table();
    var order: [max_rows]u16 = undefined;
    const n = rank("", rows, &order);
    try testing.expectEqual(@as(u16, @intCast(rows.len)), n);
    for (order[0..n], 0..) |index, i| try testing.expectEqual(@as(u16, @intCast(i)), index);
}

test "a query nothing matches ranks nothing" {
    var order: [max_rows]u16 = undefined;
    try testing.expectEqual(@as(u16, 0), rank("zzzz", table(), &order));
}

test "the ranking fits whatever room it is given" {
    var three: [3]u16 = undefined;
    try testing.expectEqual(@as(u16, 3), rank("", table(), &three));
}

test "every built-in becomes a row, with its table entry's words" {
    var rows: [max_rows]Row = undefined;
    const made = builtins(&rows);
    try testing.expectEqual(commands.table.len, made.len);
    try testing.expectEqualStrings(commands.table[0].name, made[0].name);
    try testing.expectEqualStrings(commands.table[0].about, made[0].about);

    var few: [2]Row = undefined;
    try testing.expectEqual(@as(usize, 2), builtins(&few).len);
}

test "the selection steps through what matched, and wraps" {
    const rows = table();
    var st: State = .{};
    st.field.bytes = &st.query_buf;
    st.rerank(rows);
    try testing.expectEqual(@as(u16, @intCast(rows.len)), st.shown);

    st.step(1);
    try testing.expectEqual(@as(u16, 1), st.at);
    try testing.expect(st.reveal);
    st.step(-1);
    st.step(-1);
    try testing.expectEqual(@as(u16, @intCast(rows.len - 1)), st.at);
    try testing.expectEqualStrings(rows[rows.len - 1].name, st.selected(rows).?.name);
}

test "a narrowing query keeps the selection inside what is left" {
    const rows = table();
    var st: State = .{};
    st.field.bytes = &st.query_buf;
    st.rerank(rows);
    st.at = @intCast(rows.len - 1);

    st.field.set("quit");
    st.rerank(rows);
    try testing.expect(st.at < st.shown);
    try testing.expect(st.selected(rows) != null);

    st.field.set("zzzz");
    st.rerank(rows);
    try testing.expectEqual(@as(u16, 0), st.shown);
    try testing.expect(st.selected(rows) == null);
}
