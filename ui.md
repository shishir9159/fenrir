# The reader's interface

A working plan for the chrome, the widget set, and what a plugin may put in
them. Written to be picked up cold: what is done, what is next, and the rules
that were learned the expensive way.

Read `CLAUDE.md` first for the commit conventions — they are strict and they
apply here. Read the Þviti section of `README.md` for why the UI layer is
shaped the way it is.

---

## Why this exists

`fenrir read` drew a page, a scrollbar, highlights and a caret, and nothing
else. Its mode line was the **operating system's title bar**, because a window
that cannot write in itself has nowhere else to put one. Þviti — the UI layer
— was finished as a core and exercised only by `fenrir ui` and `fenrir view`,
neither of which opens a document. The README said so outright, until phase
one was finished and it stopped being true:

> Still missing, and deliberately: a real widget set. Text fields with
> selection and an IME, menus, tab bars, trees, splitters, drag-and-drop.
> That is a layer written *on* this one.

This is that layer, and the reader's chrome built on it.

## Design language

Directly after [RAD Debugger](https://github.com/EpicGames/raddebugger), which
Þviti's core already follows — immediate-mode call sites over a retained box
cache, boxes keyed by a hash of the call-site string seeded with the parent's
key, semantic sizing with a strictness, a five-pass solver. The look follows
the same source. These are the rules every widget is written to:

- **Flat and dark by default.** Near-black ground, panels one step lighter,
  1px borders a step lighter again. No gradients. No drop shadows on chrome —
  the shadow primitive is for the page sheet and for popups only.
- **Dense.** 20px rows, 12–13px text, 6–10px gutters. A sidebar shows twenty
  things, not eight.
- **Colour carries meaning, never decoration.** The accent marks focus,
  selection and the active tab, and nothing else.
- **Keyboard first, and the interface says so.** Every command's binding is
  drawn beside it in the palette and in menus. A button is a second way to
  reach something the keymap already reaches — never the only way.
- **Hover is a lift, not a colour.** `Style.hot_lift` and `active_lift` do
  this already; no widget invents its own.
- **Tabs are an accent bar on the active one**, not a raised shape.
- **Chrome is thin and can be turned off.** Rails and bars toggle, and the
  toggle is remembered. The reader's character is chrome-free and that has to
  stay reachable.

## The screen

```
┌──────────────────────────────────────────────────────────────────┐
│ ▌paper.pdf ×│ notes.pdf ×│ +                                     │  tabpages
├──┬───────────────────────────────────────────────────────┬─┬────┤
│ ▶│                                                       │ │ ▤  │  annotations
│ ▤│                                                       │▓│ ⚑  │  bookmarks
│ ✎│                     the page                          │▓│    │
│ ✐│                                                       │ │    │
│  │                                                       │ │────│
│  │                                                       │ │  7 │  page field
│  │                                                       │ │ /48│  (editable)
├──┴───────────────────────────────────────────────────────┴─┴────┤
│ -- VISUAL --            [ fit width 138% ]  7 / 48    paper.pdf  │  status
└──────────────────────────────────────────────────────────────────┘
   ^left rail                                    ^scrollbar ^right rail
```

Left rail: normal / visual / edit, then the highlight colour palette. Draw
joins them in phase nine, when there is something behind it. These **are** the
existing keymap modes (`keys.Mode`), not a parallel concept — a rail button
goes through `keys.enter` and a swatch through `keys.paletteCommand`, which
are the same two functions the keys go through. Right rail: panel toggles at
the top, the page counter at the bottom.

The zoom is a **control**, not a reading: it says what the zoom is tied to and
what it is, and opens a menu of the four fits and six sizes. The page counter
beside it is a reading; the rail's own counter is the one that is typed into.

Panels open as an **overlay docked to the right rail**, over the page — not as
a third column that reflows it. Reflowing would refit every fitted view on
every toggle.

The tab bar is **not drawn at all while there is one tabpage**, and the rails
run to the top of the window when it is not there. A bar showing a single tab
says what the title bar already says and charges a row of the page to say it.

The search bar is the same argument taken further: it is **not in the chrome
at all** until `/` brings it into existence, floating over the top-right
corner of the page beside the right rail. Nothing opens it but the key, and
escape takes it away.

---

## Where it stands

### Phase 0 — Þviti into the reader ✅

| | Commit | |
|---|---|---|
| ✅ | `a theme the styles are read from` | `src/thviti/Theme.zig` |
| ✅ | `a ui face found on the machine` | `src/vanagandr/sysfont.zig` |
| ✅ | `the reader draws its own text` | `src/vanagandr/chrome.zig` |
| ✅ | `the mode line moves into the window` | the bar's left half |

`read.zig` holds a `Chrome` — Týr's `Fonts`, a Þviti `UI`, the glyph atlas and
its dirty-rect uploads — and draws a status bar into the `over` list after
`compose`. `windowRect` reserves the bar's height from `Layout.arrange`, so
windows stop above it rather than being covered by it.

**Known gap:** `--shot --path cpu` draws no chrome. `CpuTextures.sample` in
`read.zig` is keyed by page-image id and cannot sample a single-channel
atlas; the headless shot path is unchanged rather than broken. Closing it is
~35 lines — an atlas branch in that sampler, and a `Chrome` in `shoot`.

### Phase 1 — the widget set ✅

New files under `src/thviti/widgets/`, with `widgets.zig` re-exporting them.
Each is written the way the existing ones are: `next`, `box`, `signal`, no
privileged access to anything a caller could not reach.

| | Commit | ~ |
|---|---|---|
| ✅ | the editing model behind a text field | 345 |
| ✅ | a box whose text and key are given separately | 30 |
| ✅ | a text field widget | 398 |
| ✅ | clicking and dragging in a text field | 77 |
| ✅ | a list widget that only builds its visible rows | 444 |
| ✅ | a panel that floats over everything else | 271 |
| ✅ | menus built on the popup | 399 |
| ✅ | a tab bar | 369 |
| ✅ | icon buttons, and the tooltips that name them | 387 |
| ✅ | a splitter, and windows resized by dragging one | 487 |

`src/thviti/widgets/field.zig` holds both halves: `Field`, which is pure
arithmetic over bytes and testable with nothing at all, and `textField`, which
draws it. The field owns no string — `Field.bytes` is the caller's storage and
nothing in it allocates, the way `checkbox` takes a `*bool`. Every field in
this program is bounded (a page number, a query, a `:` line), so `insert`
returning false when full is the whole overflow policy.

`UI.boxText` was added for it: `box` and `boxf` split their label on `###`,
which is right for a label the program wrote and wrong for text a person
typed. Anything showing text from outside the program uses `boxText`.

`src/thviti/widgets/list.zig` takes a row count and a row height and builds
only the rows the scroll view can see, cutting the same seam again: `range`
is four numbers in and two row indices out, so every awkward case is asked
about with no UI at all. An iterator rather than the callback first sketched
here, because `openPanel` already makes that argument — the call site keeps
its own control flow, which is where a list wants to `continue` or to break
out early. Rows stay in the flow behind a nil-keyed spacer rather than being
floated at `index * row_height`, since `UI.positions` deliberately does not
scroll floating children.

`vanagandr/ui.zig` built all of them and let the draw list cull, which is
fine for 200 rows and wrong for a 600-page outline. Its sidebar now uses the
widget, and the `culled` counter is what says so: **163 boxes solved and
1599 instances culled became 71 and 27**, with the frame unchanged but for
the indent, which is a spacer now instead of three spaces in the label.

`src/thviti/widgets/popup.zig` is one box floated against the root, and it
is on top because it is **built last** — the same order `UI` already draws
and hit-tests in, so nothing sorts and there is no second layer. Menus,
tooltips and the command palette are all that box with different contents.
Dismissal is a clickable backdrop behind it, and the press that *opened* a
popup cannot be the press that closes it: hover is resolved by walking the
tree, so a backdrop absent when hover was last resolved is not hot, and a
press only reaches a box the pointer was already over. That frame of latency
is usually the price of immediate call sites; here it is the mechanism.

The popup and the menu are separate commits, the way the text field's model
and its widget were. The popup is the one with the argument in it.

`menu.zig` draws each command's binding dim at the right, because the design
language asks for it and a menu that hides which key runs a command has
broken the promise. Enter cannot act where it is read — the keys are read
before any item exists — so it records the index it chose and `item` reports
it as it is built. A row activated from the keyboard comes back through the
same return value as one that was clicked, and the caller cannot tell them
apart, which is the point.

`tabs.zig` is the accent bar the design language asks for and nothing else —
no raised shape, no notch. A tab asks for 180 pixels at a strictness of 0.55
rather than sizing to its title: a bar whose tabs move when a document is
opened is a bar nobody can aim at, and when there are more tabs than room
the solver shares the shortfall between all of them, so the *minimum width
is the strictness* and there is no second number to get wrong. The close
cross is a clickable box inside a clickable tab, and the inner one wins for
nothing — hover is depth-first in build order, last match taking it.

`tool.zig` takes a *string* for its glyph, which is a bookmark and not a
design — phase two hands it an icon id instead and nothing else about the
widget changes. Its tooltip is two calls, not one: `hint` records what the
pointer is resting on where the control is built, and `tooltips` draws it
at the end of the frame, because a popup is on top only by being built last.
It waits 0.45s, and the clock restarts on a different box, so a pointer
crossing a rail does not drag a tooltip across the screen with it.

One trap paid for here and worth not paying twice: **a spacer inside a box
that sizes to its children is the whole window wide.** `spacer` is `.fill`,
a percentage looks past a `children_sum` ancestor for something with a size,
and the next one up is the root. Padding inside a popup goes in the text
size's own `pad`, not in spacers.

`splitter.zig` owns one number and nothing else: the caller sizes the first
pane `.percentStrict(fraction)` and the second `.fill`. **Strict, and that
is not a detail** — `Size.percent` is loose, and if both panes will give way
the violation pass shares the overflow between them and the line lands
somewhere neither the caller nor the pointer asked for. This cost an hour.

`Layout` gets the same gesture for real windows: `dividerAt` finds the line
under a point with slack (two pixels is not a target), `moveDivider` moves
it and re-lays the tree as `split` and `close` do. A divider is named by its
node and the index of the pair it splits, never by its rectangle, because
the pointer runs ahead of the line the moment it reaches `min_side` and a
lookup would drop the gesture just as someone leans into it. `read.zig`
holds the divider for the whole drag, and closes the README's *"Windows are
resized only by the layout, not by dragging the divider."*

Only the two windows either side move: their shares sum to the same number
afterwards, so dragging one line in a row of four leaves the other two
exactly where they were.

### What phase 1 cost, against what it was budgeted

Four rows of the table became six commits: the popup split from the menu,
and the splitter from the icon buttons. Both were seams `CLAUDE.md` asks
for, and the unsplit versions would have been 670 and 874 lines.

It was still not enough. The estimates were 200 a commit and the six ran
271 to 487, averaging 393. A widget arrives with its documentation and its
tests and the three do not divide neatly — the tests are a third of every
one of these files, and the argument for why a widget is shaped as it is is
another third. The only commit that came in near the budget is the one with
no tests in it at all, `a box whose text and key are given separately`, at
thirty lines.

The seam that would actually have worked on the biggest of them is the one
the text field used and these did not: **keyboard from mouse.** The menu's
arrow keys are a hundred lines that arrive after a menu that already works
with the pointer; the splitter's `Layout` half is a hundred and fifty that
arrive after a splitter that already works on panels. Both were written in
one go because they were being written for the first time and the shape was
not settled until the end. Next phase, split them in the plan rather than
noticing afterwards.

### Phase 2 — icons ✅

Icons are **declared, never embedded**. A plugin registers
`plugin_id.icon_name`; every toolbar, menu, tab and palette entry references
that ID. Nothing outside the registry knows how an icon is drawn.

Four commits were budgeted and eight were written. Two of the splits were
planned here in advance and two were not; see the accounting below.

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | svg path data, parsed into an outline | `src/tyr/svgpath.zig` | 429 |
| ✅ | elliptical arcs in path data | `svgpath.zig` | 257 |
| ✅ | an icon face whose glyphs are built in | `src/tyr/backend/icons.zig` | 440 |
| ✅ | the icon registry: namespaced ids and slots | `src/thviti/Icons.zig` | 508 |
| ✅ | icon buttons take an icon from the registry | `widgets/tool.zig`, `vanagandr/ui.zig` | 69 |
| ✅ | `fenrir icons`, and a sheet of what it draws | `src/vanagandr/icons.zig` | 317 |
| ✅ | icon themes, read out of a lua table | `src/galdr/icons.zig` | 391 |
| ✅ | `fenrir icons` applies and checks a theme | `vanagandr/icons.zig` | 121 |

**The claim that this needs almost no new machinery held.** `Face` is a
vtable whose only required output is an `Outline`, and SVG path data is the
same operator set, so `tyr/backend/icons.zig` is a `Face` that reads a table
of `d` strings. Below it, nothing changed at all: the atlas keys on
`(face, glyph, size, subpixel)` and caches an icon per size beside the
letters, `tyr/raster.zig` fills it, and `draw.zig` emits one tinted quad. The
tint is `currentColor` for nothing, as predicted — an icon follows
`Style.fg`, so the light theme in phase three needs no second asset.

**The one design decision that was not in the plan: icons are reached by code
point, not by glyph index.** The plan's source union said `.glyph` was a face
id and a glyph index. It is a face id and a *code point*, at `U+E000` upwards
for the built-in face, because `Fonts.layout` takes a string and a `Box`
holds one. Placing a glyph by index would have meant a second path through
`Fonts`, a field on `Box` and a branch in the renderer, to arrive at what a
private-use code point already does. It is also what a theme author has: a
Nerd Fonts cheat sheet lists code points and nobody knows their indices.

**`Icons.resolve` does no work.** A `Source` is turned into a font id and the
bytes that select the glyph *at registration*, and path data reaches the icon
face at the same moment, so a themed icon and a compiled-in one are
indistinguishable from the atlas down. Resolving on a frame path is two array
indexes. That is the rule about doing nothing per frame that can be done on
change, applied where the change is a registration.

**The theme is Lua with no Lua in it.** `galdr/icons.zig` opens a state with
no libraries at all -- not the plugin sandbox, which is for code, and this is
a table -- loads one chunk in text mode only, and reads what it returns. A
theme cannot call anything, cannot reach the filesystem, is capped at four
megabytes, and is stopped by a count hook if it turns out to be a program.
The entries come back as strings and numbers: the font is a *file*, and the
library layer does not open files, so `vanagandr/icons.zig` is what opens it
and what turns `slot = "menu"` into a `Slot`.

Entries are sorted by name before they are returned, which is not tidiness:
a Lua table has no order, the icon face numbers glyphs in the order they
arrive, and an unsorted theme gives a different listing on every run of a
command whose whole purpose is to be diffed.

### What phase 2 cost, against what it was budgeted

Four commits at 250 became eight at 317 average, and 2532 lines against a
budget of 990. The estimates were wrong in the same direction as phase one's
and for the same reason -- a file arrives with its documentation and its
tests -- but two things are worth separating out.

The splits that were *planned* worked. Arcs split from the rest of the path
grammar exactly as intended: the parser landed with eight operators and a
test that says an arc is refused, and arcs replaced that test two hours
later. Applying a theme split from reading one the same way.

The splits that were *not* planned are the interesting ones, and both are the
same shape: **a table is not a feature.** `fenrir icons` was budgeted as part
of "icon themes, and `fenrir icons` to check them", and it is not — printing
the registry is what proves the registry, and it had to exist before there
was a theme to check with it. The same for the widget: handing `iconButton`
an id rather than a string is three lines of widget and a call site, and it
belongs with neither the registry before it nor the command after it.

The commit that came closest to its budget is the only one that is purely a
change to existing code, at 69 lines. Every new *file* ran between 317 and
508. That is now the honest number to plan phases three and four with: a new
file in this program costs about four hundred lines, of which a third is
tests and a third is the argument for why it is shaped as it is.

**What did not move.** Nothing on the page path was touched -- the diff for
this phase is four new files, two module roots, one widget and three
commands -- so `fenrir raster --all --stats` reports the same fills, strokes,
segments and glyphs it did before, and there is no frame-time claim to make
because no per-frame code changed. The icon face adds glyphs to the atlas
that was already there: the sheet of all twenty-eight icons at all six slots
is 113 cells and one draw call.

**Why this needs almost no new machinery.** `Face` is a vtable whose only
required output is an `Outline` — moveTo/lineTo/quadTo/cubicTo/close, which
is exactly SVG path data's operator set. `tyr/backend/fallback.zig` is the
precedent: a 100-line `Face` that synthesises its glyphs. So an **icon face**
is a `Face` whose `outline` reads a built-in path table and whose
`glyphForName("bookmark")` returns an index.

Everything downstream is then unchanged: `Atlas` keys on
`(face, glyph, size, subpixel)` and already quantises size, `tyr/raster.zig`
fills it, and `draw.zig` emits one `d.glyph(dst, atlas, src, color)` tinted
by `Style.fg`. **That tint is `currentColor`** — a symbolic variant following
the theme foreground falls out for free, in both themes, with no second asset.

- **IDs** — `plugin_id.icon_name`, interned to a `u32` at registration. Core
  icons are `fenrir.bookmark`, `fenrir.highlight`, and so on.
- **Slots** — `toolbar_large` 24, `toolbar_small` 16, `sidebar` 20,
  `statusbar` 14, `menu` 16, `tab` 16, as an enum carrying the pixel size.
- **Sources** — a tagged union: `.path` (unit-square outline) or `.glyph`
  (face id + glyph index). Per-slot overrides; absent one, the default source
  is rasterised at the slot's size, exact for `.path`.
- **Resolution** — user icon theme → plugin default → `fenrir.unknown`, drawn
  as a visible hollow box. Same argument as Týr's notdef: a missing icon that
  draws nothing is indistinguishable from a correct empty toolbar.
- **Themes** are a mapping table, ID → source, from
  `<config>/icons/<name>.lua`. A Nerd Fonts or Material theme is `.glyph`
  sources against a face opened from disk, and costs nothing new.

### Phase 3 — zoom, dark mode, settings ✅

Four commits were budgeted and five were written, one of them a bug found
while reading a paper rather than anything on this list.

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | a selection ends where the pen did | `gelgja/DisplayList.zig`, `content/Interpreter.zig`, `hlidskjalf/text.zig` | 95 |
| ✅ | fit the height and the page, beside the width | `hlidskjalf/View.zig`, `Layout.zig`, `keys.zig` | 234 |
| ✅ | the zoom becomes a control with a menu | `vanagandr/chrome.zig` | 288 |
| ✅ | a theme setting, and the light theme it picks | `mimir/Library.zig`, `vanagandr/read.zig` | 217 |
| ✅ | a settings page over what the library keeps | `src/vanagandr/settings.zig` | 679 |

`refit` is called by `Layout.arrange` on every rectangle change, so all four
fit modes survive splits and resizes for nothing — with one line changed:
the refit ran on a change of *width* only, which was right while the only fit
was the width's and wrong the moment a page could be fitted down the window.

**The light theme was already written.** `Theme.light` landed with the theme
file in phase 0 and had never been reachable. What this phase added was the
setting, and what it cost was not the theme at all: it was the four colour
literals still in `read.zig` — the backdrop, the paper, the page's shadow and
the line between two windows — which are drawn whether or not there is a
`Chrome` and so had never been anybody's theme. Three of them turned out to
be the dark theme's `paper`, `shadow` and `divider` to the hundredth. The
fourth, the backdrop, was `gray(0.16)`, which is the theme's **panel** — so
the status bar had been exactly the same grey as the ground it sat on since
the day it was written, and nobody noticed until a light theme made it
obvious. It is `ground` now, a step darker, as the design language always
said it should be.

**The interface gets first refusal on a frame, and asks its own state.**
`read.zig` handles input *before* the chrome is built, which is the right
order for everything else and impossible for a menu: escape would leave
visual mode and the arrows would scroll the page out from under the popup.
So `Session.interfaceHasInput` asks whether a menu or the settings page is
**open**, not whether a box is hot — the box tree for this frame does not
exist yet. That is the second time keeping widget state on the caller has
paid for itself, and it is the reason to keep doing it.

**A fit is named by a word in both directions.** The status bar's menu hands
back `.{ .fit = "page" }` — a string, not a `View.Fit` — because `Status` is
strings and numbers and the bar has no business knowing what a view is. It
costs nothing: `View.Fit.byName` is the parser for `:fit page` anyway, so a
menu row and a command line cannot drift.

### What phase 3 cost, against what it was budgeted

Four commits at 760 became five at 1513, and the average commit was 303 —
the first phase to land on `CLAUDE.md`'s number rather than twice it. Both
halves of that are worth separating.

**The three commits that changed existing code came in at 95, 234 and 217,**
against budgets of 150, 180 and 150. That is the first time the estimates
have been close, and the reason is that phases one and two had already built
what these needed: the menu was a widget, the popup was a widget, the theme
was a table, and the fit modes were a bool that wanted to be an enum. A phase
spent using the last two phases is a cheap phase.

**The one new file ran to 679 lines and the budget said 280.** That is the
same number phase two ended on — *a new file in this program costs about four
hundred lines* — except worse, because this one is a whole page rather than
one widget: a table of settings, a row that is either a choice or a field, a
value store, and fourteen tests. The rule holds and the estimate ignored it
again. `settings.zig` is a third documentation, a third tests and a third
code, exactly as predicted, and knowing that in advance still did not make
the number in the table right.

**The seam that would have worked** is the one phases one and two both name
and this one did not take: *split the model from the widget that draws it.*
`State` — the option table, the value store, `nextChoice` — is arithmetic
over bytes with no UI in it at all, and it is half the tests. Landing it as
`the settings a reader may change`, then `a page over them`, would have been
two commits of about three hundred and fifty, which is the shape `field.zig`
took and the shape this should have taken.

**The bug that was not on the list.** `a selection ends where the pen did` is
the smallest commit of the phase and the only one anybody reported: selecting
a paragraph drew a right-hand edge that wandered by half an em from line to
line. The cause was a guess in `hlidskjalf/text.zig` — the last glyph of a
run has no next glyph to be measured against and was given half its point
size — and the fix was to stop guessing, because the interpreter has the
number and was throwing it away. One `f32` on `TextRun`, which is per run and
not per glyph, took the spread on a page of a justified paper from 7.0 points
to 2.8, with thirty-four of forty-five lines now ending at exactly the same
x. What is left is the producer's own typesetting and not ours.

### Phase 4 — the rails and the panels ✅

Five commits were budgeted and six were written. The extra one was planned
here in advance for the first time — the keyboard split from the mouse, which
is the seam phases one and two both named after the fact.

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | the right rail, with the page number on it | `src/vanagandr/rails.zig`, `chrome.zig`, `read.zig` | 407 |
| ✅ | a page number typed into the rail | `rails.zig` | 177 |
| ✅ | a panel listing the highlights and their notes | `src/vanagandr/panels.zig`, `read.zig` | 572 |
| ✅ | the document outline, read out of `/Outlines` | `src/gjoll/outline.zig` | 622 |
| ✅ | a bookmarks panel over the outline | `Buffer.zig`, `panels.zig`, `read.zig` | 87 |
| ✅ | the left rail: modes and the colour palette | `hlidskjalf/keys.zig`, `rails.zig`, `read.zig` | 394 |

A "comment" in fenrir is a note on a highlight — one panel, not two. The
annotations panel is a list over `Buffer.marks.items()` sorted by
`Marks.readsBefore`; clicking a row calls `Session.focusMark`, which is the
same gesture `n` makes, so a row clicked and then `d` deletes the one clicked.

**`gjoll/outline.zig` sits beside `pages.zig`** and does the same kind of job:
walk `/First`/`/Next` with a depth cap and cycle detection, read `/Title`,
resolve a destination from `/Dest` or from `/A` with `/S /GoTo` — the
`[page /XYZ x y]`, `/Fit`, `/FitH`, `/FitBH` and `/FitR` forms, and named
destinations through both `/Dests` and the `/Names` name tree. It returns a
flat array with a depth per entry, which is what a list widget wants and what
makes it testable with no window. Damage tolerance as everywhere else: a
broken outline yields no bookmarks, never an error that stops the document
opening, and an entry whose destination will not resolve keeps its title and
points nowhere.

**Two files came out of `read.zig` rather than going into it**, as the table
had said. `rails.zig` and `panels.zig` follow `chrome.zig`'s division exactly:
a struct of strings and numbers in, a `Want` out, no view and no buffer
anywhere, and the whole thing built and clicked in a test with no window and
no PDF. `read.zig` was 4695 lines before this phase and would have been six
thousand after it.

**Panels are a vocabulary, not a panel per feature.** A `panels.Row` is a
label, a page, a colour chip, a depth and an id; the annotations panel and the
outline are the same widget with different rows, and that is the shape phase
eight's plugin panels are declared in. The rows are the reader's array,
refilled when `Marks.revision` or the open panel changes and at no other time.

**The left rail's modes *are* `keys.Mode`.** Two functions were added to
`keys.zig` so that they could be: `enter(state, mode)` sets the mode and
returns the command the key would have pushed, and `paletteCommand(mode,
index)` says what a colour means where it means anything. The digits go
through the second one now too, so a swatch and the key printed in its tooltip
cannot come to mean different things. That is the design language's "a button
is a second way to reach something the keymap already reaches", made
structural instead of merely intended.

**Known gap: the rails do not turn off.** The design language asks for it —
"rails and bars toggle, and the toggle is remembered" — and nothing here does.
It is a setting in `settings.zig`'s table, two bools in `windowRect`, and a
`:set` name; call it 80 lines, and it belongs with whichever phase next
touches the settings page.

### What phase 4 cost, against what it was budgeted

Five commits at 1250 became six at 2259, and the average commit was 376.

**The planned split worked, and it is the third time that seam has.** The
right rail landed as the pointer's half and then the keyboard's, 407 and 177,
because the plan said to split it rather than leaving it to be noticed
afterwards. The second half is the smallest real commit of the phase and the
one with the fewest surprises in it: a field, three tests, and nothing to
argue about, because the argument was settled by the commit before.

**The split that was not planned is the same one phase three missed.** `a
panel listing the highlights and their notes` is 572 lines because the panel
widget and the reader's row-building landed together. `panels.zig` alone is
400 — a `Row`, a `State`, a list and six tests — and the reader's half is 120:
the sort, the staleness check and the click. Landing them as *a panel of
typed rows* and then *the highlights in one* would have been two commits of
about three hundred and fifty. **Split the model from the widget that draws
it** has now been the answer three phases running and been taken once.

**`outline.zig` is the fourth data point for four hundred lines a file, and
the first that is not a widget.** It came in at 622 with ten tests, and the
thirds hold exactly: the argument for why a destination is three grammars and
one answer, the tests that write a malformed PDF down and say what comes out,
and the walk itself. The seam inside it that was there to take: `decode` — a
PDF text string as UTF-8 — is eighty lines of arithmetic over bytes with no
document anywhere in it, and it is the piece nothing else in the program had
and several things will want. *Pdf text strings, as utf-8* was a commit.

**The cheapest commit of the phase is the one that used the two before it.**
`a bookmarks panel over the outline` is 87 lines: a field on `Buffer`, a
`switch` arm that turns entries into rows, and the scroll. Phase three said a
phase spent using the last two phases is a cheap phase; a *commit* spent using
the last two commits is a cheap commit, and it is worth ordering a phase so
that there is one.

### Phase 5 — tabpages ✅

Two commits were budgeted and four were written. The two extra are the same
two seams this plan has now named four times: the forward-looking change split
off in front, and the model split from the widget that draws it.

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | a layout leaf holds a pane, not a view index | `hlidskjalf/Layout.zig` | 62 |
| ✅ | tab pages, each with its own split tree | `src/hlidskjalf/Tabs.zig` | 393 |
| ✅ | the reader in tabpages: gt, :tabnew and ctrl-w T | `keys.zig`, `read.zig` | 408 |
| ✅ | the tab bar, once there are two tabpages | `chrome.zig`, `rails.zig`, `panels.zig`, `read.zig` | 235 |

A tabpage owns a `Layout`, as in Vim. `Tabs` is a list of them plus an active
index; `Session` holds a `Tabs` where it held a `Layout`, and `layout()` is
the one on screen. `:tabnew`, `:tabclose`, `:tabonly`, `:tabn`/`:tabp`,
`gt`/`gT`, `<C-w>T`.

**The bar was already written.** `thviti/widgets/tabs.zig` landed in phase one
with its accent mark, its crosses, its middle-click and its strictness, and it
has been exercised by `fenrir ui` and by nothing else since. The reader's half
of that commit is the two hundred lines around it: which tabs there are, what
they are called, and what a click on one means. **A widget written a phase
early and left untouched still fitted**, which is worth more than it sounds —
it is the first evidence that phase one built a widget set rather than four
widgets for four call sites.

**`g` is a prefix and `<C-w>` is a chord, and that is not a detail.**
`State.pending` became a `Prefix` enum, and the two are completed in different
places: the window prefix from key events before the text loop, `g` from
inside it. They have to be. `Input.typedKey` folds case on purpose — a layout
reporting `W` for the `w` key should still answer to `<C-w>w` — and `gt` and
`gT` are two commands that differ *only* in their case. What is right for a
chord is wrong for a letter.

**The last window of a tabpage closes the tabpage.** `closeWindow` returns
`closeTab()` where it used to return false, which makes `q` mean exactly what
it means in Vim at every level: close the window, and if that was the last
window close the tab, and if that was the last tab leave. One line, and it is
the only place in the reader that knows the three are nested.

**The bar is not drawn for one tabpage**, and `windowRect` takes nothing off
the top when there is not one, so a session that never opens a tab looks
exactly as it did before this phase. That is also why `Chrome.top` exists: the
rails and the panel float against the top of the window and have to be told
how much of it is already spoken for, and the reader is the only thing that
knows.

### What phase 5 cost, against what it was budgeted

Two commits at 430 became four at 1098, and the average commit was 274 — the
first phase whose average is under three hundred. Phase four planned one split
in advance and found the second afterwards; this one planned both, and neither
had to be noticed.

**The forward-looking change is cheap exactly once.** `a layout leaf holds a
pane, not a view index` is 62 lines and one test. It would have been the same
62 lines inside the tabpages commit and invisible there, and it will be free
in the phase that adds a canvas, because the callers that have to change have
already changed. The plan named it in advance; naming it is what made it a
commit.

**`Tabs.zig` is the fifth data point for four hundred lines a file**, and the
thirds hold again: 130 of documentation, 120 of code, 140 of tests. The rule
has not missed yet.

**The keyboard and the mouse split themselves this time.** `gt` and `:tabnew`
landed in one commit and the bar in the next, and the second is 235 lines
because the first had already settled what a tab *is*, what closing one does
to the places it was left at, and what a selection does when the window it was
made in goes off screen. That is the cheap commit phase four asked for and it
was ordered on purpose.

**The tests cannot see this one, and knowing that in advance is the point.**
The rails and the panel are floated at `fixed_y = 0`, so a bar above them is
something they have to be *told* about — and every test of all three passes
`top = 0`, because until this phase there was nothing above them and there
still is not in a test. The check that a rail starts under the bar is a
picture and can only be a picture: `newTab` twice at the top of the session, a
`--device` shot in each theme, and both taken out again before the commit.

### Phase 6 — the command registry and the palette ✅

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | commands, in a table with their names | `hlidskjalf/commands.zig`, `vanagandr/commands.zig` | 438 |
| ✅ | ranking the commands against what was typed | `vanagandr/palette.zig` | 459 |
| ✅ | the command palette, on ctrl-p and :commands | `palette.zig`, `keys.zig`, `read.zig` | 615 |

`Session.exec` dispatched on `std.meta.stringToEnum(Builtin, …)` — names with
no descriptions and nothing to enumerate. The registry is one array of
`{ id, name, aliases, args, about, icon, binding, modes }`; `exec` looks a
name up and runs the same switch it always ran. `<C-p>` and `:commands` open
the palette over the page; a row runs its command, and a row that needs an
argument puts its name on the `:` line with a space after it.

**The abbreviations were the enum's real cost.** `q`, `sp`, `vs`, `tabn`,
`bn` were a second dozen tags, which made every arm read `.q, .quit =>` and
made the list of commands unenumerable — twelve of the thirty-three names
were spellings of another name and nothing said so. As `aliases` they are
data: `find` walks them, the listing prints them in a column, and the palette
searches them, so `sp` finds `:split` in all three places from one table.

**The mode mask is the one field nothing narrows yet, and it was still right
to put in.** Every built-in is offered in every mode. It is there because a
plugin's command already declares one — Galdr's keymaps have carried a
`ModeSet` since they were written — and the palette merges the two lists into
one array of rows. A row that could not say which modes it belongs in would
have had to be two kinds of row, and phase eight would have added the field
anyway, to a table with call sites.

### What phase 6 cost, against what it was budgeted

Two commits at 530 became three at 1512, and the average commit was 504 — the
worst of any phase here, and against a rule that asks for three hundred.

**A table is not a small commit, and calling it one is the mistake.** The
budget said 250 for the registry and it landed at 438 with the command that
prints it. The table itself is 30 lines of data; the other 400 are the
documentation of what a field means, the checks that no two commands answer
to the same word, and `fenrir commands`. The same thing happened in phase two
with the icons. **The estimate to make for a registry is the estimate for a
file, four hundred lines, and not the estimate for its data.**

**The table was written out one field a line and it was unreadable.** Eight
lines an entry for twenty-six entries is a page of braces, and the thing
being checked by eye — that twenty-six rows agree about their column widths,
their voice, their icons — cannot be checked across a page of braces. Written
one entry a line it is 30 lines and a column can be read down. The reason the
first version came out long is that every other struct in this program is
written that way, and every other struct is not a table.

**`fenrir commands --match` is the half of a palette a picture cannot check.**
A `--device` shot says the list is drawn, in the right colours, with the last
row whole. It says nothing at all about whether `tn` should have found
`tabnew` before `tabonly`, which is the half that decides whether the palette
is any good. Printing the ranking with the score beside each row made that a
diff, and it is how the description matcher was found to be wrong: matching a
sentence as a subsequence, `ce` hit twenty of twenty-five commands. A
substring there and a subsequence in the name is the whole fix, and it took
one run of a command that already existed to see it.

**The picture found what the picture always finds, which is a number.** The
popup's height was `pad * 2 + 26 + rows * 26`, which looks right and leaves an
eleventh row cut in half at the bottom, because the list is `.fill` and slack
at the bottom of a scroll view is not padding — it is another row. Twelve
tests over the ranking, the keyboard, the clicks and the dismissal all passed
with it wrong. That is the third phase running where the tests covered the
behaviour and a shot covered the geometry.

**A control that appears already wanting the keyboard has to ask, and has to
name itself correctly.** The settings page learned this in phase three, and
the palette got it wrong anyway: the focus key was `palette/query` and the
field is `palette/head/query`, because it is inside the row that holds it.
Nothing crashed, nothing looked wrong in a shot — the palette simply did not
take what was typed, which was two tests failing in a way that named the box
rather than the bug. **A key worked out by hand is a path, and a path is
wrong until something walks it.**

**Two names for two palettes.** `Session.palette` was the left rail's eight
highlight colours and the command palette wanted the same word. The colours
became `swatches`, which is what they are. A field renamed on the day a second
meaning arrives costs three lines; the same rename after the second meaning
has call sites is the kind of change nobody makes.

### Phase 7 — text as characters, then search ✅

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | what a character code means: /ToUnicode and the encoding chain | `gjoll/content/Font.zig`, `gelgja/DisplayList.zig`, `Builder.zig`, `tyr/encoding.zig` | 757 |
| ✅ | a page's text as a string, and the word gap it turns out to be | `hlidskjalf/text.zig`, `View.zig`, `vanagandr/trace.zig` | 346 |
| ✅ | searching a document, a page at a time, wrapping where it started | `src/hlidskjalf/search.zig`, `vanagandr/trace.zig` | 525 |
| ✅ | the search bar, on slash, with n and N stepping the matches | `src/vanagandr/find.zig`, `read.zig`, `keys.zig` | 757 |

`text.Box.code` was the raw content-stream code and nothing turned it into a
letter. `/ToUnicode` is parsed now — `bfchar`, both forms of `bfrange`, and
UTF-16BE destinations, so a ligature is the two letters it stands for — and
behind it the encoding chain, `/Differences` over `/BaseEncoding` over
Standard, ending at a glyph name that `tyr.encoding` turns into a code point.
A simple font's whole map is resolved once when the font is loaded; a
composite font gets `/ToUnicode` and nothing else, because its codes are CIDs
into a character collection this program does not have.

The search bar **appears only on `/`**: not in the chrome until a search
begins, takes focus, highlights matches on the visible pages, steps with
`n`/`N`, and escape closes it and clears them. The scan runs on the existing
`Rasteriser` worker thread, last in the queue behind everything on screen,
and reports incrementally — so the count reads `4+` while it is running and
`12` when it has finished.

### What phase 7 cost, against what it was budgeted

Four commits at 980 became four at 2385, which is two and a half times the
estimate and the worst overrun of any phase here. Three of the four are over
five hundred lines and two are at seven hundred and fifty.

**The estimate was for the feature and the cost was for the format.** 250
lines was the honest size of "read `/ToUnicode`". What landed at 757 is that
parser plus a span type in Gelgja with its lookup, a builder call that sorts
and rebases it, the `bfrange` array form, surrogate pairs, the truncation
bound, a fold of three encoding tables at comptime, and eleven tests. None of
that is padding and none of it could be left out: a `/ToUnicode` map that
handled only the common shape would be a map that silently mangled a quarter
of the documents anyone owns. **The rule from phase six generalises past
registries: estimate the file, and estimate a file per format the commit has
to understand.**

**The layering question was decided by arithmetic, not by taste.** Gjöll has
imported nothing but Gelgja since it was written, and the encoding chain
needed Týr's three tables. Copying them would have been two thousand lines of
the same data in two places. They are *PDF's* encodings — Annex D of the
specification, not any font format's — and they live in Týr only because Týr
was the first thing that needed them. The import is written down at the top
of `Font.zig` with that argument, which is the least a new edge in the
dependency graph deserves.

**`space_after` was wrong from the day it was written, and only a printer
could show it.** The field guessed a word boundary from an advance longer
than a glyph's. The first `fenrir trace --text` of a real paper came out as
`AnA lternativeView :W henDo` — no space between any two words, and a
spurious one after every `A`, `W` and `m`. The reason is structural: a `TJ`
kern moves the text matrix, which *ends the run*, so an interword gap is
never inside a run at all — and inside a run every offset comes from
`/Widths` plus a spacing that is the same for every glyph, so a long advance
there is a wide letter and nothing else. The rule it was looking for could
not fire, and the rule it did fire on could only be wrong. It is a gap
between boxes, it always was, and `wordStart` had already been measuring that
gap correctly beside it for three phases.

**The numbers that fixed it were printed, not reasoned about.** Twelve lines
of throwaway code in `trace --lines` printed every gap on a line with the
glyph height beside it: within a word, −0.5 to 0; between words, 3.5 and up,
at a height of 13.6. That is not a close call and no amount of reading the
code would have produced either number. The threshold had been right all
along — it was being consulted in one place and ignored in the other.

**A picture of a search is a picture of nothing, because the search has not
run yet.** `--shot` waits until the visible pages are ready and then fires,
and the scan is deliberately last in the job queue — so the shot is taken in
the first frame in which the search is allowed to start. Six hundred frames
of waiting produced a bar saying `searching` over a page with no matches on
it. Seeding one page's hits inline before the window opens is what made the
picture, and the picture is what found the colour bug below. **A background
feature has to be *stood still* before it can be photographed, and the two
lines that do it come out again with the popup-opening ones.**

**The accent is white, and a white wash over white paper is nothing at all.**
The matches were drawn in `s.accent` at a highlight's alpha, which on the
only kind of page most documents have is invisible. `read.zig` already says
this in a comment three hundred lines above, about why a highlight made
without a colour is grey — and the selection's grey and the caret's blue are
both fixed constants for the same reason. The matches are now the selection's
grey with the caret's blue on the one being stood on, and the argument is
written beside them: **the page underneath is the document's colour, and
anything the interface draws on it has to be a colour, not the theme's.**

**`n` meant the next page and Vim means the next match.** Both, and which one
depends on whether a search is live — with `<space>` keeping the page
movement unconditionally, so nothing was taken away. A key that means two
things is usually a mistake; this one is not, because the two never overlap:
`n` steps matches exactly while a bar is on screen saying how many there are,
and escape takes the bar away and gives the key back.

**Removing a heuristic made the reader faster.** `wordGap` sorted up to 256
floats per text run, and a page of a paper is sixteen hundred runs. Taking it
out is the whole of why `read --frames 1200` came in at 0.692s against
0.734s: the phase added a Unicode lookup per glyph and still ran six per cent
faster than the phase before it. Measured interleaved, best of five.

### Phase 8 — what a plugin may contribute ✅

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | a plugin manifest, and the capabilities it asks for | `galdr/Runtime.zig`, `lua.zig`, `galdr.zig`, `plugins.zig` | 525 |
| ✅ | an event bus, with patterns and async handlers | `galdr/Runtime.zig`, `lua.zig`, `read.zig`, `plugins.zig` | 626 |
| ✅ | plugins put icons and buttons on the rails | `Runtime.zig`, `rails.zig`, `read.zig`, `plugins.zig` | 412 |
| ✅ | plugin commands in the palette, settings in the page | `Runtime.zig`, `settings.zig`, `read.zig` | 459 |
| ✅ | panels declared by a plugin | `Runtime.zig`, `panels.zig`, `rails.zig`, `read.zig` | 587 |
| ✅ | `fenrir health` | `src/vanagandr/health.zig`, `main.zig`, `Library.zig` | 494 |
| ✅ | the plugin api, written out of the api table | `Runtime.zig`, `plugins.zig` | 251 |
| ✅ | headless: run a plugin over a document with no window | `src/vanagandr/run.zig`, `Runtime.zig`, `library.zig` | 538 |

**Capabilities.** A manifest — `plugins/<name>/plugin.lua` returning a table,
or a `fenrir.manifest{…}` call at the top of a single-file plugin — declares
`document.read`, `document.write`, `network`, `filesystem`, `clipboard`,
`signature`, `redaction`, `ui`. The sandbox is already stated positively by
the `Host` vtable, so enforcement is structural and cheap: **build that
plugin's `fenrir` table with only the granted functions in it.** An ungranted
call is not a refusal at run time, it is `nil`. `network` and `clipboard` have
nothing behind them yet and are reserved names only.

**The event bus.** `Payload` grows from six events to the vocabulary below,
with Vim's autocommand shape: `fenrir.on(event, pattern, fn)` where the
pattern is a glob on the document path, and groups so a reloaded plugin can
clear its own. Handlers become **coroutines**, resumed by the host — which is
what "async by default" has to mean here, since a handler that blocks blocks
the frame. The existing instruction limit becomes a limit per *resumption*, so
a long handler yields instead of being killed.

Half the event vocabulary names features that do not exist. Reserve the names,
document them as reserved, and do not fire them:

| Event | Status |
|---|---|
| `DocOpen`, `PageChanged`, `ModeChanged`, `Quit` | fires today (renamed from `open`/`page`/`mode`/`quit`) |
| `SelectionChanged` | lands with this phase; the data is in `View.selection` |
| `AnnotationAdd`/`Remove`/`Change` | fires today as `highlight` |
| `PageRender` | fires **once per page completion**, on the frame thread, from `collectPage` — never per frame, and never on the rasterising thread, which owns the `Document` and cannot also own a Lua state |
| `ThemeChanged` | **reserved.** The theme landed in phase three; the bus it would fire on is this one, and `Session.useTheme` is the one place that would fire it |
| `DocSave` | **reserved.** fenrir cannot write PDFs at all |
| `FormFieldFocus` | **reserved.** Annotations draw from appearance streams; none is interactive |
| `BeforeRedact` | **reserved.** No redaction exists |

Contributions all take an icon *ID*, never a path, and go through new `Host`
vtable entries, so Galdr still knows nothing about windows. A panel is
declared as a list of typed rows — `{kind, icon, label, detail, action}` — a
vocabulary Lua can build and Þviti can lay out without a plugin ever touching
a box. The status line uses the same rows.

### What phase 8 cost, against what it was budgeted

Eight commits at 1930 became eight at 3892, which is twice the estimate and a
shade better than phase seven's two and a half. Every one is over 250 lines
and three are over 500. The pattern from phase six holds and has not been
beaten: **estimate the file, not the feature** — and this phase added five
registries, a coroutine scheduler, two commands and a contribution type per
half of the interface, each of which arrives with its paragraph, its test and
the command that prints it.

**There is no global `fenrir`, and that is the whole of the sandbox.** The
plan said "build that plugin's `fenrir` table with only the granted functions
in it", and the half it did not say is where the table goes: a global one is a
global one, and a narrowed plugin that could write `_G.fenrir` would have been
narrowed in name only. So every chunk runs with an environment of its own —
an empty table whose metatable reads and writes through to `_G`, with
`fenrir` as its one real field. That is four lines in `newEnv`, it costs one
table per plugin, and it makes the enforcement structural: **an ungranted
function is not refused, it is `nil`.** The knock-on is that `require` has to
load a module into *the requiring chunk's* environment, which is one line and
would have been a silent hole otherwise.

**A coroutine's hook is not the state's hook.** Lua 5.4 keeps the debug hook
per thread and a new thread inherits none, so the step limit — the whole of
what stops `while true do end` — was simply absent on every handler the moment
handlers became coroutines. Nothing failed: the tests passed, the reader ran,
and a runaway handler would have hung the window with no message. `lua_sethook`
on each coroutine as it is made is the fix, and it is one line that is
invisible until the day it is not there. **A limit that is enforced per thread
has to be installed per thread, and a test that only proves the good case
proves nothing about it.**

**`lua_resume` counts the arguments and not the function.** The first run of
the event bus had every handler silently not running: the coroutine was made,
the function and its table were moved onto it, and the resume said two
arguments when there was one argument and a function under it. Three tests
failed and all three said "the handler never ran", which is the symptom and
not the cause. **When a boundary takes a count, write down what is being
counted beside it** — the comment is now there, and it is the only thing that
makes the number readable.

**A picture found a bug that eleven tests could not see.** `panels.Row` grew a
`detail` field, the tests checked that a row with a detail had no page number
beside it, and they passed — because the box the detail drew into had no size
and drew nothing, which is also "no page number". The shot of a plugin's panel
is what showed four rows with three empty right-hand ends. **`.w` and `.h` are
not optional and a box without them is not a small box, it is no box**, which
is a thing this interface has now learned in two phases running from two
directions.

**A second picture found a lie the reader had been telling.** The palette's
shot with a plugin's command in it showed `redo <C-r>` and `Read <C-r>` one
above the other: the plugin had bound the chord and the built-in table's
`binding` string is a constant that cannot know. Nothing crashed, both rows
were correct in isolation, and the pair was wrong. The palette now parses each
built-in's binding back through `keyspec` and asks the plugin keymap whether
that key is still theirs. **A binding drawn beside a command is a claim about
the keyboard, and the keyboard is the thing that has to be asked.**

**Two commands that write to the same table have to key it the same way.** A
script's highlights went into the library under the path as typed, and
`fenrir marks` and `fenrir read` both key on the *real* path — so `fenrir run`
wrote highlights that no other command in the program could ever find. The
round trip is two commands and was ten seconds to check, and nothing short of
running both would have shown it. `library.absolute` is public now with that
argument written on it.

**A `--shot` runs with no plugins, on purpose, and that is the one thing that
makes a plugin hard to photograph.** A picture has to be the same picture
whatever is in somebody's configuration directory, so `read.zig` skips Galdr
for a shot — which means the three pictures this phase needed were taken by
deleting that condition, taking them, and putting it back. That is the same
two lines the popups need, from the other side, and it belongs in the list
with `menu.show(…)`.

**Performance is unchanged, and that was the point.** `fenrir read F
--frames 1200 --vsync off` came in at 0.717s before and 0.724s after, measured
interleaved, best of twelve — a one per cent difference on a machine whose two
batches disagreed by eight. Nothing was expected to move: the reader with no
plugins does not enter `pump` at all, and with plugins it compares one
revision number per frame and rebuilds the rail lists only when a plugin has
changed them. `fenrir raster --all` is 1.979s against 1.984s and **all ten
pages hash identically**, which is what the rule asks for.

### Phase 9 — freehand ink ✅

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | an ink table in mímir, and `fenrir marks --ink` | `mimir/Library.zig` schema v3, `library.zig` | 418 |
| ✅ | ink as a mark: stored, drawn on the page, erased with a click | `Marks.zig`, `View.zig`, `read.zig`, `run.zig`, `Host.zig` | 672 |
| ✅ | draw mode: the pointer is a pen, and a left-rail button | `keys.zig`, `commands.zig`, `rails.zig`, `read.zig`, `icons.zig` | 526 |

A stroke is a page, a colour, a width and a point list in PDF user space — the
space highlights already use, so it survives zoom and reopening. Draw is a
`keys.Mode` and a left-rail button like the others, and undo goes through
`Marks`' existing history rather than a second one: a stroke **is** a mark,
with a `kind`, so the history, the effects queue, the revision number, the
annotations panel, `n`/`N` in edit mode and the eraser on a click all took ink
without a line of their own.

`d` enters draw mode from normal — it was the one free letter that says what
it does. A digit picks the pen's colour from the same eight swatches the
highlighter uses (`keys.paletteCommand` answers for `.draw` too), `[` and `]`
make it thinner and thicker as a factor, the way `zoom_by` is, and `d`, `q`
or escape leave. A plugin binds in draw mode with the letter `"d"`, and every
annotation a plugin is handed carries `kind = "block"` or `"ink"`.

### What phase 9 cost, against what it was budgeted

Two commits at 450 became three at 1616, which is three and a half times the
estimate and the worst ratio since phase six. The plan named two files and the
work touched eleven. What it did not count: the model half (`kind`, a hit test
that is a distance to a line, `simplify`), the command that prints the table,
the plugin surface in three places, the reader's help, and a test for each —
which is *estimate the file* for the fifth phase running, and the plan for
this one was written before that rule was.

**The plan's rendering line was wrong, and the algorithm under it was
right.** "Render through `gleipnir/stroke.zig`" assumed a pipeline that is not
there. `stroke.zig` produces a path; the only path pipeline in the reader draws
*the page*, on the worker thread, behind a `Scene` recorded once per zoom; and
the overlay ink has to share with the highlights is the instance pipeline, whose
file explains at length why an instance is never rotated. What transferred was
the idea `stroke.zig` is built on — stamping, not offsetting, and round is a
whole circle — so a stroke is a row of discs half a radius apart, each a
rounded box whose radius is half its side. Same algorithm, reached through the
pipeline that exists, with the same property that chose it: no case analysis.

**A box is where a mark is, and not what it is.** A stroke's `box` is its
bounds, so everything that asks *where* — the visible range, reading order,
the panel — asks one field for both kinds. But a click asks *what*, and a
circle drawn round a figure would have swallowed every click inside the figure.
`Mark.hits` is a distance to the polyline for ink and the box for a block. The
same argument is why a plugin is told `kind`: a bounding box is a true answer to
the wrong question.

**The draw icon was a pencil, and so was the one above it.** `fenrir.draw` had
been in the icon table since phase two, a pen with a nib. The first shot of the
rail showed it directly under `fenrir.edit`, a pencil with a nib, and at
sixteen pixels they were the same diagonal. It is a squiggle now. Both icons
were correct about what they named, which is not what an icon is for.

**The regression was a button.** `read --frames 1200` with an empty library
came in at 785ms against 758ms, best of eight, and after was slower in seven
of the eight rounds — so not noise. Nothing on the ink path runs without ink:
the walks are over an empty list. Taking the fourth mode button off the rail
and measuring again gave 793ms against 812ms, and putting it back gave 782ms
against 815ms in the next batch, which is this machine's drift between batches
— the same size as the difference being chased. So: the cost is one more
`iconButton` a frame, it is smaller than what this machine can measure between
two batches, and the reader has one more mode to have a button for. What made
it an answer rather than a shrug was taking the button out, not reading the
diff. `fenrir raster --all` is 1.825s against 1.833s, best of five, and **all
ten pages hash identically**.

**The largest commit split along the seam that compiles.** The draw-mode work
was 1053 lines as it was written. The seam this document names — the model
from the thing that draws it — was not where it could be cut, because adding
`.draw` to `keys.Mode` makes every exhaustive switch on it fail to compile
until each is answered, and those switches are in the reader. The seam that
does compile is one step earlier: ink as a *mark* first, with nothing in the
keymap, drawn from rows `fenrir marks --ink` wrote; then the mode that makes
them. Each half builds, has its tests, and has its picture.

**A picture's temporary lines can write to the library.** A stroke seeded
with the pen down, for a shot of a stroke being drawn, was committed on the
first frame — the shot's pointer had no button held, so the pen came up — and
it is in the scratch database that shot used. `--shot` does not remember a
place, but a change to the marks is written whoever made it. Shoot against a
scratch `--db`, which is also what made this the round trip the phase eight
rule asks for: the reader wrote a stroke and `fenrir marks` listed it.

### Phase 10 — comparing documents

| Commit | Files | ~ |
|---|---|---|
| `fenrir diff`, page by page | `src/vanagandr/diff.zig` | 300 |
| two documents side by side, with the changes washed | `read.zig` | 280 |
| a word-level diff over the text | `hlidskjalf/search.zig` neighbours | 280 |

Layered. The CLI first, so it is testable with no window: pair pages, compare
their `gelgja.DisplayList` commands, report added/removed/moved regions,
reusing the image-difference reporting `fenrir raster --path both` already
prints. Then the side-by-side view with synchronised scrolling. The word-level
diff is cheap once a page is a string.

---

## Decisions taken for the canvas

An embedded canvas beside the page, in the manner of LiquidText, is intended
but not planned here. Three choices are made so it stays cheap:

1. **`Layout`'s leaf payload becomes a `Pane` union**, not a view index. A
   canvas is another variant, not a second layout system.
2. **Panels are overlays, not a third column.** A canvas can then be a real
   pane in the split tree without competing with the sidebars.
3. **An excerpt is a clipped replay of a page's `Scene`**, which `Recorded` in
   `read.zig` already caches per page. Mímir's new tables take an
   `id INTEGER PRIMARY KEY` and reference documents by `path`, as `highlight`
   does, so a canvas can reference excerpts across documents without a schema
   change.

## Recommended against

- **WebP icons.** A new codec written from scratch, thousands of lines, for
  something `.path` and `.glyph` already do better at every size.
- **Full inline SVG.** The `d=` subset is ~260 lines and covers every icon set
  worth having. Groups, transforms, gradients, masks and CSS make SVG a second
  document format to maintain beside PDF.
- **PNG icons, for now.** `gleipnir/png.zig` is a *writer*; there is no
  decoder. One is ~250 lines using `std.compress.flate` and the existing
  `gjoll/filter/predictor.zig`, and is worth adding only if a real icon set
  needs it. The registry's source union is where it would go.
- **A `PageRender` hook per frame.** Calling Lua at the refresh rate breaks
  the no-allocation-per-frame rule and would put a Lua state on the
  rasterising thread, which owns the `Document`.

---

## Rules learned here

Things that cost time once and should not cost it again.

- **The library layer does not open files; the CLI does.** Týr and Þviti touch
  no filesystem at all, and `galdr/Host.zig` states the rule. That is why the
  system-font search is `vanagandr/sysfont.zig` and not `tyr/system.zig`.
- **Anything holding an interior pointer goes on the heap.** `UI` reaches text
  through a vtable holding `&chrome.fonts`. Returning a `Chrome` by value
  copies it and leaves that pointer aimed at a dead frame — which does not
  crash where it is made, it crashes three calls later inside Týr with an
  empty face table. `Chrome` uses `create`/`destroy`, like `galdr.Runtime` and
  a buffer's `Document`.
- **`ui.root` does not exist until `begin` has made one.** A key seeded from
  `ui.root.key` before the first frame is a hash of whatever was on the stack.
- **Three ids have to agree for the atlas**: the device texture, and an entry
  in *each* draw list, so a glyph's texel source rectangle can be normalised
  at record time. `Chrome.attach` registers all three before any page slot,
  and asserts. When they disagree, a page draws as the interface's own glyphs
  scattered over it.
- **Let the sizes do the eliding.** The status bar's left group asks for the
  whole bar at strictness 0 and clips; the right group asks for its children
  at strictness 1. A message longer than the window is cut at the page number
  instead of pushing it out. That is one rule in the sizing, not a string
  measured and truncated every frame.
- **A registry is not usable until something prints it.** `fenrir icons`
  found three wrong paths and two icons that drew nothing, in the minute
  after it first ran, and none of them would have been found by reading the
  table. Every registry in this program gets its command in the same commit
  it gets its table, not in a later one.
- **Draw the thing before committing the thing.** Twenty-eight icons all
  parsed, stayed inside the em, and had the right number of contours, and
  the tests said so. Two of them were still unreadable at sixteen pixels. A
  throwaway test that rasterises to ASCII art in the terminal took five
  minutes to write and is the only reason this phase did not ship a pen that
  looked like a smear.
- **A face copied by value cannot report a count that grows.** `Fonts` holds
  `Face` structs by value, so `info.num_glyphs` is a snapshot; the icon face
  gains glyphs whenever a theme adds path data. It reports zero, as Týr's
  fallback does and for the fallback's stated reason, and the live number is
  on the `Set` behind it.
- **A colour literal outlives the file that replaced it.** `Theme.zig` landed
  in phase 0 and `read.zig` still had four colours of its own three phases
  later, because nothing drawn in the dark looked wrong. The check that
  actually finds these is not reading the code, it is *running the other
  theme* — one of the four turned out to be the panel grey and had made the
  status bar invisible against its own backdrop since the day it was written.
- **Ask the widget's state, not the box tree, when you are early in the
  frame.** Input is handled before the chrome is built, so "is a menu
  swallowing this key" cannot be answered by hover: there is no tree yet.
  It is answered by the menu's own `open`, which is on the caller for exactly
  this reason — the same argument as a checkbox's bool, arrived at twice.
- **A control that appears already wanting the keyboard has to ask for
  focus.** Focus follows a press, and the press that turned a settings row
  into a text field landed on the box the field *replaced*. The field has to
  set focus on itself the frame it first appears, which means knowing its key
  before it exists — which is free, since a key is a hash of the call-site
  string seeded with its parent's.
- **A box does not clip the text it draws itself — only what its children
  draw.** A label that has to be cut short needs a parent that clips and a
  text box sized to its own text inside it. The status bar's rule is the same
  rule from the other side and reads as though it were about strictness; it is
  not, it is about which box the `clip` flag is on. The first outline drawn in
  a panel had a heading running out from under its own row and over the page
  number beside it, and a `--device` shot is what said so.
- **Reserve a rail; overlay a panel; and that is what decides who gets the
  click.** A rail comes off `windowRect` the way the status bar's height does,
  so a pointer over a rail is never also over a page and there is nothing to
  arbitrate. A panel floats over the document, so it records its rectangle as
  it is built and `Session.pointer` asks before it hands a press to the text.
  That is the only pointer arbitration in the reader, and it exists because
  reflowing the windows for a list somebody opened to glance at would refit
  every fitted view on every toggle.
- **Last frame's rectangle is not a wrinkle, it is the answer.** A panel reads
  `box.rect` as it builds, which is before this frame is solved and after the
  last one was — and that is exactly the rectangle that was under the pointer
  when the button went down. The test needs two frames before it can ask, and
  saying so in the test is better than working around it.
- **Two ways into the same thing go through one function.** `keys.enter` and
  `keys.paletteCommand` exist because a rail button that built its own command
  would be a second keymap with no tests and no name. The rule generalises:
  wherever the interface offers a second way to something the keyboard already
  reaches, the second way calls what the first one calls — it does not
  reimplement the switch.
- **Verify the parser through the thing that will use it, and commit in that
  order.** `outline.zig` was written, wired to a panel, photographed against a
  real paper, and only then committed — in two commits, parser first. Ten
  tests over hand-written fixtures said the walk was right; the picture is
  what said the *destinations* were, and it is also what found the clipping
  bug above. Neither would have been found by reading the code.
- **What is right for a chord is wrong for a letter.** `Input.typedKey` folds
  case deliberately, because a layout that reports `W` for the `w` key should
  still answer to `<C-w>w`. `gt` and `gT` are two commands that differ only in
  their case, so they cannot be read through it — they are read from the
  codepoint, in the loop over the frame's text. Two prefixes, completed in two
  places, and the reason is which kind of key each one is followed by.
- **A floating box has to be told what is above it.** Both rails and the panel
  are pinned at `fixed_y = 0`, which was the whole answer while the only
  chrome above the page was nothing. The tab bar put something there, and none
  of the three could find that out for itself: `ui.viewport` is the window,
  not the space left in it. It is one number passed down from the reader —
  `Chrome.top` — for the same reason `reserved_below` is a constant in
  `rails.zig`, and the tests of all three still pass zero, because in a test
  there is nothing above them. A picture is the only check.
- **A registry costs what a file costs, not what its data costs.** The icon
  table and the command table were both budgeted at their rows and both came
  in at four hundred lines, because a registry arrives with a paragraph per
  field explaining what it means, a test that no two rows collide, and the
  command that prints it. Estimate the file.
- **A table is written one entry a line.** Every other struct in this program
  is written one field a line and a table is not another struct: the thing
  being checked by eye is that twenty-six rows agree with each other about
  their voice, their columns and their icons, and that cannot be checked
  across a page of braces. Twenty-six entries are thirty lines, not two
  hundred.
- **A key worked out by hand is a path, and the path is wrong until something
  walks it.** The palette's field asks for focus before it exists, which means
  naming it — and the name was `palette/query` where the box is
  `palette/head/query`, because it sits inside the row that holds it. Nothing
  crashed and no shot looked wrong; the field simply never took what was
  typed. A test that types a letter and reads it back is the check, and it is
  two lines.
- **A ranking is the half of a list that a picture cannot check.** A shot says
  the rows are drawn and the last one is whole. It says nothing about whether
  `tn` should have found `tabnew` before `tabonly`, which is the half that
  decides whether a palette is worth opening. `fenrir commands --match`
  prints the order with the score beside each row, which makes a change to the
  scoring a diff — and is how matching a description as a subsequence was
  found to hit twenty of twenty-five commands for `ce`.
- **Rename a field the day a second meaning arrives.** `Session.palette` was
  the left rail's eight colours and the command palette wanted the word. The
  colours became `swatches` in three lines. The same rename once the second
  meaning has call sites is the kind nobody makes, and the two live side by
  side being confused for each other for a year.
- **A heuristic that cannot fire is worse than no heuristic, and only the
  output says which you have.** `space_after` guessed a word boundary from a
  long advance, and a long advance inside a run is a wide letter: a `TJ` kern
  ends the run, so the gap it was hunting for is never inside one. Twelve
  tests passed over it, a caret and a selection used it for three phases, and
  the first page printed as a string came out with no spaces in it and one
  after every `A`. **When a rule is about what a format can contain, check
  what the format can contain.**
- **Print the numbers before choosing the threshold.** The fix above needed
  one measurement: the gaps between adjacent glyphs, with the glyph height
  beside them. Within a word, −0.5 to 0; between words, 3.5 and up. Twelve
  throwaway lines in a command that already existed, and the answer was not a
  close call — which is the difference between a threshold and a guess that
  has a number in it.
- **A colour for the page cannot come from the theme.** The accent is white
  by default, and white at a wash's alpha over white paper leaves the paper
  exactly as white as it was. The selection's grey and the caret's blue are
  fixed constants and say so; search matches are now the same two, for the
  same reason. Anything the interface draws *on the document* is its own
  colour, because the document is not the interface's to tint and the theme
  cannot know what the paper is.
- **Estimate the file, and one file per format.** Phase six learned this for
  registries and phase seven paid it again: `/ToUnicode` is 250 lines of
  parser and 757 lines of commit, because a format arrives with its edge
  cases -- a `bfrange` array, a surrogate pair, a destination that is a glyph
  name -- and each of them is a test and a paragraph.
- **A new edge in the dependency graph is written down where it is made.**
  Gjöll had imported nothing but Gelgja until the encoding chain needed Týr's
  three tables. The alternative was two thousand lines of the same data
  twice. The import is at the top of `Font.zig` with the argument beside it:
  those tables are the PDF specification's, not a font format's, and they are
  in Týr only because Týr needed them first.
- **Background work has to be stood still before it can be photographed.** A
  search is last in the job queue on purpose, and `--shot` fires the moment
  the visible pages are ready -- which is the first frame the scan is allowed
  to begin. The picture was of a bar saying `searching` over a page with
  nothing on it. Seeding one page's results before the window opens is what
  made the shot, and it comes out again with the `menu.show(…)` lines.
- **A sandbox that leaves a global is not a sandbox.** Capabilities narrow the
  `fenrir` table a plugin is handed, and a *global* `fenrir` beside it would
  have made that narrowing decorative: `local f = _G.fenrir` and it is gone.
  Every chunk gets an environment of its own — one table, a metatable that
  reads and writes through to `_G`, and `fenrir` as its single real field —
  and there is no global one at all. The check is one line of Lua in a test:
  `assert(rawget(_G, "fenrir") == nil)`.
- **A limit enforced per thread has to be installed per thread.** Lua 5.4's
  debug hook is per coroutine and a new one inherits none, so the instruction
  limit vanished the day handlers became coroutines — silently, with every
  test still green, because a test of the *good* case proves nothing about a
  runaway. `lua_sethook` goes on each coroutine as it is made, and the test
  that matters is the one that hangs without it.
- **When a boundary takes a count, write down what is being counted.**
  `lua_resume` counts arguments, not the function under them, and passing two
  where one was meant made every event handler not run — reported by three
  tests as "the handler never ran", which is the symptom three times over. The
  number is now next to a sentence saying what it is.
- **A box with no size is not a small box, it is no box.** A panel row's new
  `detail` drew nothing because its `ui.next` had no `.w` and no `.h`, and the
  test that should have caught it asked whether the *page number* was absent —
  which it also was. A shot of the panel is what showed three empty right-hand
  ends. The same lesson as the clipping one, from the other side.
- **A binding drawn beside a command is a claim about the keyboard.** The
  built-in table's `binding` is a constant, a plugin can bind the same chord,
  and the palette then draws two rows claiming `<C-r>`. Parse the string back
  through `keyspec` and ask the live keymap who owns the key. Nothing crashes
  and nothing looks wrong until two rows sit one above the other in a picture.
- **Two commands that write to one table have to key it the same way.**
  `fenrir run` stored highlights under the path as typed; `read` and `marks`
  key on the real path. Both worked, and neither could see the other's work.
  The check is the round trip -- write with one, list with the other -- and it
  is ten seconds.
- **A shot runs with no plugins on purpose, so a contribution has to be
  photographed by hand.** `read.zig` skips Galdr for `--shot` so that a
  picture is the same picture whatever is in somebody's configuration
  directory. Every picture this phase needed came from deleting that condition
  and putting it back, which is the `menu.show(…)` rule in a second place and
  is worth knowing before spending an hour wondering where the rails went.
- **A plan that names a file for the drawing is naming a pipeline, so check
  the pipeline is there.** Phase nine was to "render through `stroke.zig`",
  which makes paths, and the only path pipeline draws the page on another
  thread. The overlay has instances and no rotation. The algorithm crossed
  over (stamp discs, as `stroke.zig` itself does) and the file did not.
  Anything that has to appear under the pointer this frame goes through the
  overlay, whatever shape it is.
- **A box is where a mark is, not what it is.** Bounds are the right answer
  for the visible range, reading order and a panel, and the wrong one for a
  click: a circle drawn round a figure would take every click inside it. Ask
  the mark (`Mark.hits`), and tell a plugin `kind` for the same reason.
- **An icon has to differ from the one beside it.** The draw pen and the edit
  pencil each named the right thing and were the same shape at sixteen pixels.
  The icon sheet shows each icon alone; only a shot of the rail shows them
  next to each other, so take that shot whenever a button is added to a rail.
- **Take the suspect out and measure again.** Three and a half per cent on a
  path with nothing to draw was one more rail button a frame. Reading the diff
  would not have found that, because the diff for ink does nothing without ink.
  A run with the button removed found it in one build.
- **Add a variant to an exhaustive enum in the commit that answers it.** Every
  `switch` on `keys.Mode` stops compiling the moment `.draw` exists, so the
  mode and everything that switches on it land together. When that is too
  large, split *before* the enum grows: ink as a mark first, with nothing in
  the keymap, then the mode. A split after the enum grows only makes a commit
  that does not build.
- **Shoot against a scratch `--db`.** `--shot` does not remember a place, but
  a mark changed during a shot is written. The temporary lines that set up a
  picture can change marks, and that change goes into whichever library the
  shot opened.
- **Commits here have been running large, and should not.** `CLAUDE.md` asks
  for under about three hundred lines, and the repository's own code commits
  before this work ran 60–272. The interface commits have landed between 30
  and 615, because a widget arrives with its documentation and its tests and
  the three do not divide neatly. Two seams that did work, and are worth
  reaching for first: split a *model* from the *widget that draws it* (the
  text field), and split the *keyboard* from the *mouse* (the same). Splitting
  so that one commit draws nothing is not a seam, it is bookkeeping.

## Verifying a change

In roughly this order:

```
zig build test                          # must be green before committing
zig build -Doptimize=ReleaseSafe
zig build -Dsqlite=false -Dlua=false    # must compile; its tests skip cleanly
zig build -Dtarget=x86_64-linux-gnu     # if the change touches Lyngvi or the build

fenrir ui --out ui.png [--atlas a.png]  # the whole stack, no GPU: fastest look at a layout
fenrir read F --shot s.png --path cpu   # the composed reader frame, no display
fenrir read F --shot s.png --device     # what the GPU actually drew, read back

fenrir icons [--out sheet.png]          # every icon, and whether it draws
fenrir commands [--match QUERY]         # every `:` command, and how it ranks
fenrir trace F --text                   # the page as the words it came out as
fenrir trace F --lines                  # the same, with the geometry beside it
fenrir trace F --all --find Q           # every match, and the boxes it covers

fenrir marks F [--db D]                 # every highlight and line of ink, as stored
fenrir marks F --ink P X Y X Y ...      # a stroke with no mouse: seed one for a shot

fenrir health                           # what this build has, and what it found
fenrir plugins                          # what a configuration registered
fenrir plugins --api                    # the whole `fenrir` table, out of the table
fenrir run S.lua F.pdf                  # a plugin over a document, no window
```

Most of the new code is testable with no window, no device and no font —
Þviti's solver, `keys`, `Layout`, `Marks`, and everything planned for
`outline.zig` and `svgpath.zig`. That is where the tests go.

**A popup cannot be photographed by a shot, so open it by hand.** `--shot`
draws one frame of a reader nobody has clicked in, which is every menu and
every panel closed — and, since phase eight, no plugins either, because a
picture has to be the same picture whatever is in somebody's configuration
directory. Two or three lines at the top of the session — `menu.show(…)`,
`settings.show()`, or `startPlugins` without its `shot == null` — and a
`--device` shot is the picture, and all of them come out again before the
commit. Note also that `--shot --path cpu` alone draws the *page* and no
chrome at all: a rail, a panel or a palette needs `--device`. That is *draw the thing before committing the thing*
applied to the half of the interface a shot cannot reach, and it is how the
zoom menu and the settings page were each found to be a few pixels out.

**Performance is part of the contract.** Chrome is drawn every frame, so a
change to it gets the standard treatment from `CLAUDE.md`: build both
binaries, keep them, run them *interleaved* in one session, best of N with
N ≥ 5. For the reader that is `fenrir read F --frames 1200 --vsync off`; a
worktree at the previous commit is the easy way to get the other binary.
`thviti/draw.Renderer`'s `boxes_drawn` and `glyphs_drawn` are the check that
a panel is not rebuilding an off-screen list. `fenrir raster F --all --stats`
must not move at all — nothing in this plan touches the page rasteriser.

Every new registry gets a command that prints it — `fenrir icons`,
`fenrir commands`, `fenrir health` — so a wrong table is a diff rather than
something to find by clicking. Phase eight added five registries and they are
all in two places: `fenrir health` prints the registries themselves, whether
or not anybody has written a plugin, and `fenrir plugins` prints what one
configuration did with them.
