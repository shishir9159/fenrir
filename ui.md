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

### Phase 6 — the command registry and the palette

| Commit | Files | ~ |
|---|---|---|
| commands, in a table with their names | `src/hlidskjalf/commands.zig` | 250 |
| the command palette | `read.zig` | 280 |

`Session.exec` dispatches on `std.meta.stringToEnum(Builtin, …)` — names with
no descriptions and nothing to enumerate. The registry is one array of
`{ name, aliases, description, icon, mode_mask }`; `exec` looks it up and then
runs the same switch. One source of truth, and the palette, the menus and
`fenrir commands` all read it. Plugin commands come from
`Runtime.commandNames()` and keymaps from `keymapList()`, both of which
already exist.

### Phase 7 — text as characters, then search

| Commit | Files | ~ |
|---|---|---|
| `/ToUnicode`, and glyph names as a fallback | `gjoll/content/Font.zig` | 250 |
| a page's text as a string | `hlidskjalf/text.zig` | 200 |
| searching a document, on the worker thread | `src/hlidskjalf/search.zig` | 250 |
| the search widget | `read.zig` | 280 |

**Nothing maps character codes to Unicode today.** `text.Box.code` is the raw
content-stream code. The pieces exist and are only unwired: the CMap parser
deliberately skips the ToUnicode operators, and `tyr/encoding.unicodeForName`
and `Font.glyphName` are both there. For a simple font the chain is
`glyphName` → `unicodeForName`, falling back to `encoding.nameFor(kind, code)`
for the base encodings; for a composite one it is `beginbfchar` /
`beginbfrange` in the existing parser.

The search widget **appears only on `/`**: not in the chrome until a search
begins, takes focus, highlights matches on the visible pages, steps with
`n`/`N`, and escape closes it and clears them. The scan runs on the existing
`Rasteriser` worker thread and reports incrementally, so a search in a
600-page document does not stall a frame.

### Phase 8 — what a plugin may contribute

| Commit | Files | ~ |
|---|---|---|
| a plugin manifest, and the capabilities it asks for | `galdr/Runtime.zig`, `Host.zig` | 280 |
| an event bus, with patterns and async handlers | `galdr/Runtime.zig` | 300 |
| plugins put icons and buttons on the rails | `Runtime.zig`, `Host.zig`, `read.zig` | 250 |
| plugin commands in the palette, settings in the page | `Runtime.zig`, `read.zig` | 220 |
| panels declared by a plugin | `Runtime.zig`, `read.zig` | 300 |
| `fenrir health` | `src/vanagandr/health.zig` | 200 |
| the plugin api, written out of the api table | `Runtime.zig`, `plugins.zig` | 180 |
| headless: run a plugin over a document with no window | `src/vanagandr/run.zig` | 200 |

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

### Phase 9 — freehand ink

| Commit | Files | ~ |
|---|---|---|
| an ink table in mímir | `mimir/Library.zig` schema v3 | 150 |
| draw mode | `keys.zig`, `read.zig` | 300 |

A stroke is a page, a colour, a width and a point list in PDF user space — the
space highlights already use, so it survives zoom and reopening. Render
through `gleipnir/stroke.zig`, which already does caps, joins and miters.
Draw becomes a `keys.Mode` and a left-rail button like the others; undo goes
through `Marks`' existing history rather than a second one.

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
- **Commits here have been running large, and should not.** `CLAUDE.md` asks
  for under about three hundred lines, and the repository's own code commits
  before this work ran 60–272. The interface commits have landed between 30
  and 472, because a widget arrives with its documentation and its tests and
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
```

Most of the new code is testable with no window, no device and no font —
Þviti's solver, `keys`, `Layout`, `Marks`, and everything planned for
`outline.zig` and `svgpath.zig`. That is where the tests go.

**A popup cannot be photographed by a shot, so open it by hand.** `--shot`
draws one frame of a reader nobody has clicked in, which is every menu and
every panel closed. Two lines at the top of the session — `menu.show(…)`, or
`settings.show()` — and a `--device` shot is the picture, and both come out
again before the commit. That is *draw the thing before committing the thing*
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
something to find by clicking.
