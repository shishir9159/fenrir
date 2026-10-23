# The reader's interface

The plan for the chrome, the widget set, and what a plugin may put in them:
what is done, what is next, and the rules learned the expensive way. Read
`CLAUDE.md` for the commit rules and README's Þviti notes for why the UI layer
is shaped as it is.

`fenrir read` used to draw a page, a scrollbar, highlights and a caret. Its
mode line was the operating system's title bar, and Þviti was exercised only
by `fenrir ui` and `fenrir view`. This is the layer written on Þviti, and the
reader's chrome built on it.

## Design language

After the [RAD Debugger](https://github.com/EpicGames/raddebugger), which
Þviti's core already follows.

- **Flat and dark by default.** Near-black ground, panels a step lighter, 1px
  borders a step lighter again. No gradients. Shadows only for the page sheet
  and popups.
- **Dense.** 20px rows, 12–13px text, 6–10px gutters.
- **Colour carries meaning.** The accent marks focus, selection and the active
  tab, and nothing else.
- **Keyboard first, and the interface says so.** Every command's binding is
  drawn beside it. A button is a second way to something the keymap reaches,
  never the only way.
- **Hover is a lift, not a colour** (`Style.hot_lift`, `active_lift`).
- **Tabs are an accent bar on the active one**, not a raised shape.
- **Chrome is thin and can be turned off**, and the toggle is remembered.

## The screen

```
┌──────────────────────────────────────────────────────────────────┐
│ ▌paper.pdf ×│ notes.pdf ×│ +                                     │  tabpages
├──┬───────────────────────────────────────────────────────┬─┬────┤
│ ▶│                                                       │ │ ▤  │  annotations
│ ▤│                                                       │▓│ ⚑  │  bookmarks
│ ✎│                     the page                          │▓│    │
│ ~│                                                       │ │    │
│  │                                                       │ │────│
│  │                                                       │ │  7 │  page field
│  │                                                       │ │ /48│  (editable)
├──┴───────────────────────────────────────────────────────┴─┴────┤
│ -- VISUAL --            [ fit width 138% ]  7 / 48    paper.pdf  │  status
└──────────────────────────────────────────────────────────────────┘
   ^left rail                                    ^scrollbar ^right rail
```

- **Left rail**: the modes (normal, visual, edit, draw) and the colour
  swatches. These *are* `keys.Mode`: a button goes through `keys.enter` and a
  swatch through `keys.paletteCommand`, the functions the keys use.
- **Right rail**: panel toggles at the top, the typed-into page counter at the
  bottom.
- **The zoom is a control**: it names what the zoom is tied to and opens a
  menu of the fits and sizes.
- **Panels overlay the page from the right rail.** A third column would refit
  every fitted view on every toggle.
- **The tab bar is not drawn for one tabpage.** It would repeat the title bar
  and cost a row of page.
- **The search bar does not exist until `/`.** It floats top right, and
  escape removes it.

---

## Where it stands

### Phase 0 — Þviti into the reader ✅

| | Commit | |
|---|---|---|
| ✅ | `a theme the styles are read from` | `src/thviti/Theme.zig` |
| ✅ | `a ui face found on the machine` | `src/vanagandr/sysfont.zig` |
| ✅ | `the reader draws its own text` | `src/vanagandr/chrome.zig` |
| ✅ | `the mode line moves into the window` | the bar's left half |

`read.zig` holds a `Chrome` (Týr's `Fonts`, a Þviti `UI`, the glyph atlas and
its dirty-rect uploads) and draws the status bar into the `over` list after
`compose`. `windowRect` reserves the bar's height, so windows stop above it.

### Phase 1 — the widget set ✅

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

Under `src/thviti/widgets/`, each written as the existing widgets are (`next`,
`box`, `signal`, no privileged access).

- **`field.zig`** is `Field`, pure arithmetic over bytes, and `textField`,
  which draws it. The caller owns the storage; every field here is bounded, so
  `insert` returning false is the whole overflow policy. `UI.boxText` exists
  because `###` splitting is right for program text and wrong for typed text.
- **`list.zig`** builds only visible rows. `range` is four numbers in and two
  indices out, so every edge case is tested without a UI. It is an iterator,
  not a callback, so the call site keeps `continue` and `break`. The demo
  sidebar went from 163 boxes and 1,599 culled instances to 71 and 27.
- **`popup.zig`** is one box floated against the root and on top because it is
  **built last**. There is no second layer. The press that opens a popup
  cannot close it: the backdrop did not exist when hover was last resolved.
- **`menu.zig`** draws each binding dim at the right. Enter records the index
  it chose, and `item` reports it, so a keyboard activation and a click come
  back the same way.
- **`tabs.zig`** is the accent bar and nothing else. A tab asks for 180px at
  strictness 0.55 rather than its title's width, so tabs do not move when a
  document opens.
- **`tool.zig`**'s tooltip is two calls: `hint` where the control is built,
  `tooltips` at the end of the frame. It waits 0.45s and restarts on a new
  box.
- **`splitter.zig`** owns one number. `Layout.dividerAt` and `moveDivider`
  give real windows the same gesture. A divider is named by node and pair
  index, never by rectangle, so the drag survives the pointer outrunning
  `min_side`. Only the two panes either side move.

### Phase 2 — icons ✅

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

- **Icons are declared, never embedded.** Toolbars, menus, tabs and the
  palette reference `plugin_id.icon_name`, interned to a `u32`. Nothing
  outside the registry knows how an icon is drawn.
- **No new machinery.** SVG path data is `Face`'s operator set, so the icon
  face is a `Face` reading a table of `d` strings. The atlas, `tyr/raster.zig`
  and `draw.zig` are unchanged, and the tint is `Style.fg`, so the light theme
  needs no second asset.
- **Reached by code point**, from `U+E000`, not by glyph index. A box holds a
  string, and a Nerd Fonts cheat sheet lists code points.
- **`Icons.resolve` does no work.** A source becomes a font id and bytes at
  registration; a frame does two array indexes.
- **Slots** `toolbar_large` 24, `toolbar_small` 16, `sidebar` 20, `statusbar`
  14, `menu` 16, `tab` 16. **Resolution** is the user theme, then the plugin
  default, then `fenrir.unknown`, drawn as a hollow box so that a missing icon
  is visible.
- **A theme is Lua with no Lua in it.** It is a state with no libraries, one
  text chunk, a 4 MB cap and a count hook, read as strings and numbers.
  `vanagandr/icons.zig` opens the font file, because the library layer opens
  no files. Entries are sorted, because a Lua table has no order and the
  listing is meant to be diffed.

### Phase 3 — zoom, dark mode, settings ✅

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | a selection ends where the pen did | `gelgja/DisplayList.zig`, `content/Interpreter.zig`, `hlidskjalf/text.zig` | 95 |
| ✅ | fit the height and the page, beside the width | `hlidskjalf/View.zig`, `Layout.zig`, `keys.zig` | 234 |
| ✅ | the zoom becomes a control with a menu | `vanagandr/chrome.zig` | 288 |
| ✅ | a theme setting, and the light theme it picks | `mimir/Library.zig`, `vanagandr/read.zig` | 217 |
| ✅ | a settings page over what the library keeps | `src/vanagandr/settings.zig` | 679 |

- `Layout.arrange` refits on every rectangle change, so all four fits survive
  splits and resizes. The refit used to fire on a width change only.
- The light theme had existed since phase 0. The cost was four colour
  literals left in `read.zig`. One of them was the panel grey, which had made
  the status bar invisible against its backdrop; it is `ground` now.
- `Session.interfaceHasInput` asks whether a menu or the settings page is
  **open**, because input is handled before this frame's box tree exists.
- A fit is named by a word both ways. `View.Fit.byName` parses `:fit page`
  and the menu's answer, so the two cannot drift.
- The selection bug: the last glyph of a run was given half its point size
  as width. One `f32` on `TextRun` from the interpreter cut the ragged right
  edge from 7.0 to 2.8 points.

### Phase 4 — the rails and the panels ✅

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | the right rail, with the page number on it | `src/vanagandr/rails.zig`, `chrome.zig`, `read.zig` | 407 |
| ✅ | a page number typed into the rail | `rails.zig` | 177 |
| ✅ | a panel listing the highlights and their notes | `src/vanagandr/panels.zig`, `read.zig` | 572 |
| ✅ | the document outline, read out of `/Outlines` | `src/gjoll/outline.zig` | 622 |
| ✅ | a bookmarks panel over the outline | `Buffer.zig`, `panels.zig`, `read.zig` | 87 |
| ✅ | the left rail: modes and the colour palette | `hlidskjalf/keys.zig`, `rails.zig`, `read.zig` | 394 |

- A comment is a note on a highlight. The annotations panel lists
  `Buffer.marks` in `Marks.readsBefore` order, and a click calls
  `Session.focusMark`, as `n` does.
- **`outline.zig`** walks `/First`/`/Next` with a depth cap and cycle
  detection, and resolves `/Dest` or `/A /GoTo` in the `/XYZ`, `/Fit`,
  `/FitH`, `/FitBH` and `/FitR` forms, through `/Dests` and the `/Names`
  tree. It returns a flat array with depths. A broken outline yields no
  bookmarks, never an error.
- **`rails.zig` and `panels.zig` came out of `read.zig`**, not into it. Each
  takes strings and numbers and returns a `Want`, and is tested with no
  window and no PDF.
- **Panels are a vocabulary.** A `panels.Row` is a label, page, colour chip,
  depth and id. Rows are rebuilt only when `Marks.revision` or the open panel
  changes.

### Phase 5 — tabpages ✅

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | a layout leaf holds a pane, not a view index | `hlidskjalf/Layout.zig` | 62 |
| ✅ | tab pages, each with its own split tree | `src/hlidskjalf/Tabs.zig` | 393 |
| ✅ | the reader in tabpages: gt, :tabnew and ctrl-w T | `keys.zig`, `read.zig` | 408 |
| ✅ | the tab bar, once there are two tabpages | `chrome.zig`, `rails.zig`, `panels.zig`, `read.zig` | 235 |

- A tabpage owns a `Layout`, as in Vim, and `Session` holds a `Tabs`. The
  commands are `:tabnew`, `:tabclose`, `:tabonly`, `:tabn`/`:tabp`,
  `gt`/`gT` and `<C-w>T`.
- The bar written in phase one fitted untouched. That is evidence of a widget
  set rather than four widgets for four call sites.
- `g` is a prefix completed from typed text; `<C-w>` is a chord completed from
  key events. `gt` and `gT` differ only in case, and `typedKey` folds case.
- `closeWindow` returns `closeTab()`, so `q` closes the window, then the tab,
  then the reader, exactly as in Vim.
- `Chrome.top` tells the rails and panel how much of the top is taken.

### Phase 6 — the command registry and the palette ✅

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | commands, in a table with their names | `hlidskjalf/commands.zig`, `vanagandr/commands.zig` | 438 |
| ✅ | ranking the commands against what was typed | `vanagandr/palette.zig` | 459 |
| ✅ | the command palette, on ctrl-p and :commands | `palette.zig`, `keys.zig`, `read.zig` | 615 |

- The registry is one array of `{ id, name, aliases, args, about, icon,
  binding, modes }`. `exec` looks a name up and runs the switch it always ran.
  `<C-p>` and `:commands` open the palette, and a row needing an argument
  lands on the `:` line.
- Vim's abbreviations are `aliases`: data that `find`, the listing and the
  palette all search.
- The mode mask narrows nothing yet. It exists because plugin commands already
  carry one, and the palette merges both lists.
- The description is matched as a substring and the name as a subsequence.
  As a subsequence, `ce` matched twenty of twenty-five descriptions.
- The rail's eight colours were renamed `swatches`, the day "palette" gained
  a second meaning.

### Phase 7 — text as characters, then search ✅

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | what a character code means: /ToUnicode and the encoding chain | `gjoll/content/Font.zig`, `gelgja/DisplayList.zig`, `Builder.zig`, `tyr/encoding.zig` | 757 |
| ✅ | a page's text as a string, and the word gap it turns out to be | `hlidskjalf/text.zig`, `View.zig`, `vanagandr/trace.zig` | 346 |
| ✅ | searching a document, a page at a time, wrapping where it started | `src/hlidskjalf/search.zig`, `vanagandr/trace.zig` | 525 |
| ✅ | the search bar, on slash, with n and N stepping the matches | `src/vanagandr/find.zig`, `read.zig`, `keys.zig` | 757 |

- `/ToUnicode` is parsed, including `bfchar`, both `bfrange` forms and
  UTF-16BE, so a ligature is two letters. Behind it is the chain
  `/Differences` → `/BaseEncoding` → Standard → glyph name → code point. A
  simple font resolves its whole map once. A composite font gets
  `/ToUnicode` only.
- Gjöll now imports Týr's three encoding tables. They are PDF's (Annex D),
  and copying them would be two thousand lines twice. The argument is at the
  top of `Font.zig`.
- `space_after` could never fire: a `TJ` kern ends the run, so a word gap is
  between boxes. Printing the gaps settled it: −0.5 to 0 inside a word, 3.5
  and up between words.
- The scan runs on the `Rasteriser` worker, last in the queue, reporting as it
  goes (`4+`, then `12`).
- Matches are the selection's grey, with the caret's blue on the current one.
  The white accent would vanish on white paper.
- `n` steps matches while a search is live and turns the page otherwise.
  `<space>` always turns it.
- Dropping `wordGap`'s sort made `read --frames 1200` 6% faster (0.734s to
  0.692s), despite a Unicode lookup per glyph.

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

- **Capabilities.** A manifest (`plugins/<name>/plugin.lua`, or
  `fenrir.manifest{…}`) asks for `document.read`, `document.write`, `ui`, or
  the reserved `network`, `filesystem`, `clipboard`, `signature` and
  `redaction`. That plugin's `fenrir` table holds only what was granted, and
  there is no global one. An ungranted function is `nil`, not a refusal.
- **The event bus.** `fenrir.on(event, pattern, fn, group)`, shaped like
  Vim's autocommands. Handlers are coroutines resumed by the host, with an
  instruction limit per resumption. Events that name features which do not
  exist yet are reserved and never fired.
- **Contributions** (rail buttons, panels as typed rows `{kind, icon, label,
  detail, action}`, settings, commands) take icon ids and go through `Host`,
  so Galdr knows nothing about windows.
- Performance did not move: `read --frames 1200` measured 0.717s against
  0.724s, and `raster --all` 1.979s against 1.984s, with every page hashing
  the same. A reader with no plugins never enters `pump`.

| Event | Status |
|---|---|
| `Start`, `DocOpen`, `PageChanged`, `ModeChanged`, `Quit` | fire |
| `SelectionChanged`, `AnnotationAdd`/`Remove`/`Change` | fire |
| `PageRender` | once per page completion, on the frame thread, never on the rasteriser's |
| `ThemeChanged`, `DocSave`, `FormFieldFocus`, `BeforeRedact` | reserved, not fired |

### Phase 9 — freehand ink ✅

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | an ink table in mímir, and `fenrir marks --ink` | `mimir/Library.zig` schema v3, `library.zig` | 418 |
| ✅ | ink as a mark: stored, drawn on the page, erased with a click | `Marks.zig`, `View.zig`, `read.zig`, `run.zig`, `Host.zig` | 672 |
| ✅ | draw mode: the pointer is a pen, and a left-rail button | `keys.zig`, `commands.zig`, `rails.zig`, `read.zig`, `icons.zig` | 526 |

- A stroke is a page, a colour, a width and points in PDF user space. It **is**
  a mark with a `kind`, so history, effects, the revision, the panel, `n`/`N`
  and the eraser took ink without a line of their own.
- `d` enters draw mode. Digits pick the pen's colour through
  `keys.paletteCommand`, `[`/`]` scale the width by a factor, and `d`, `q` or
  escape leave. Plugins bind draw mode with `"d"` and see
  `kind = "block" | "ink"`.
- A stroke is drawn as a row of discs half a radius apart: stamping, as
  `stroke.zig` does, through the overlay's instance pipeline. The only path
  pipeline draws the page on another thread.
- `Mark.hits` measures the distance to the polyline for ink and uses the box
  for a highlight. A circle drawn round a figure must not swallow clicks
  inside it.
- `read --frames 1200` went from 758 to 785ms. Removing the fourth rail
  button showed the cost was that button, within this machine's drift.
  `raster --all` hashes were unchanged.

### What each phase cost

Estimates have been low in the same direction every phase. This table is
what to plan with.

| Phase | Planned | Landed | Avg lines | Lesson |
|---|---|---|---|---|
| 1 | 4 commits at 200 | 6 commits, 2,357 lines | 393 | split the keyboard from the mouse |
| 2 | 4, 990 lines | 8, 2,532 | 317 | a table is not a feature; a new file is ~400 lines |
| 3 | 4, 760 | 5, 1,513 | 303 | split the model from the widget that draws it |
| 4 | 5, 1,250 | 6, 2,259 | 376 | the planned split worked; the unplanned one was missed again |
| 5 | 2, 430 | 4, 1,098 | 274 | a forward-looking change is cheap exactly once |
| 6 | 2, 530 | 3, 1,512 | 504 | a registry costs a file, not its rows |
| 7 | 4, 980 | 4, 2,385 | 596 | estimate a file per format the commit must understand |
| 8 | 8, 1,930 | 8, 3,892 | 487 | estimate the file, not the feature |
| 9 | 2, 450 | 3, 1,616 | 539 | split before an exhaustive enum grows |

### Open gaps

- **`--shot --path cpu` draws no chrome.** `CpuTextures.sample` cannot sample
  the single-channel atlas. Fixing it is about 35 lines: an atlas branch there,
  and a `Chrome` in `shoot`.
- **The rails do not turn off.** Fixing it takes a setting, two bools in
  `windowRect`, and a `:set` name, about 80 lines, in whichever phase next
  touches settings.

### Phase 10 — comparing documents

| Commit | Files | ~ |
|---|---|---|
| `fenrir diff`, page by page | `src/vanagandr/diff.zig` | 300 |
| two documents side by side, with the changes washed | `read.zig` | 280 |
| a word-level diff over the text | `hlidskjalf/search.zig` neighbours | 280 |

Build the CLI first, so it is testable with no window. Pair pages, compare
their display lists, and report added, removed and moved regions the way
`raster --path both` reports. Then comes the side-by-side view with
synchronised scrolling. The word diff is cheap once a page is a string.

---

## Decisions taken for the canvas

An embedded canvas beside the page, in the manner of LiquidText, is intended.
Three choices keep it cheap:

1. **`Layout`'s leaf is a `Pane` union** (done in phase 5). A canvas is
   another variant, not a second layout system.
2. **Panels are overlays**, so a canvas can be a real pane without competing
   with them.
3. **An excerpt is a clipped replay of a page's `Scene`**, which `Recorded` in
   `read.zig` already caches per page. New Mímir tables take an
   `id INTEGER PRIMARY KEY` and name documents by `path`, as `highlight` does.

## Recommended against

- **WebP icons.** Thousands of lines of codec for what `.path` and `.glyph`
  do better.
- **Full inline SVG.** The `d=` subset covers every icon set worth having.
  Groups, transforms, gradients and CSS would be a second document format.
- **PNG icons, for now.** There is no PNG decoder. One would be about 250
  lines on `std.compress.flate` and `gjoll/filter/predictor.zig`; add it when
  something real needs it.
- **A `PageRender` hook per frame.** It would allocate per frame and put a Lua
  state on the rasterising thread, which owns the `Document`.

---

## Rules learned here

**Layers and ownership**
- **The library layer opens no files; the CLI does.** That is why the font
  search is `vanagandr/sysfont.zig`.
- **Anything holding an interior pointer lives on the heap.** A `Chrome`
  returned by value leaves `UI`'s pointer to its fonts aimed at a dead frame,
  and the crash comes three calls later inside Týr.
- **A new edge in the dependency graph is argued where it is made**, as at the
  top of `Font.zig`.
- **Two ways into one thing go through one function.** `keys.enter` and
  `keys.paletteCommand` exist so a rail button is not a second, untested
  keymap.
- **Two commands that write one table key it the same way.** `fenrir run`
  stored marks under the typed path, and nothing else could find them. The
  check is the round trip: write with one command, list with the other.
- **A sandbox that leaves a global is not a sandbox.** The test is one line:
  `assert(rawget(_G, "fenrir") == nil)`.
- **A limit enforced per thread is installed per thread.** Lua's hook is per
  coroutine, and the instruction limit vanished when handlers became
  coroutines, with every test green. The test that matters is the one that
  hangs without it.
- **When a boundary takes a count, write down what it counts.** `lua_resume`
  counts arguments, not the function under them.

**The box tree**
- **`ui.root` does not exist until `begin` has made one.**
- **Three ids must agree for the atlas:** the device texture and an entry in
  each draw list. `Chrome.attach` registers all three and asserts. When they
  disagree, the page draws as scattered interface glyphs.
- **Let the sizes do the eliding.** The status bar's left group asks for
  everything at strictness 0 and clips, and the right group is strict. No
  string is measured and cut per frame.
- **A box clips what its children draw, not its own text.** A label to be
  cut needs a clipping parent.
- **A box with no size is no box.** It draws nothing, and a test asking what
  is absent passes.
- **A spacer inside a box that sizes to its children is the window wide.**
  Pad with the text size's `pad`.
- **Split panes are strict** (`percentStrict`). If both give way, the line
  lands where nobody asked.
- **A floating box has to be told what is above it** (`Chrome.top`). Tests
  pass zero, so only a picture checks it.
- **Early in the frame, ask the widget's state, not the tree.** Input comes
  before the chrome is built, so "is a menu open" is `menu.open`.
- **A control that appears wanting the keyboard asks for focus**, by a key
  known before it exists. A key worked out by hand is a path and is wrong
  until something walks it: `palette/query` was `palette/head/query`.
- **Last frame's rectangle is the answer.** It is the rectangle that was under
  the pointer when the button went down.
- **Reserve a rail; overlay a panel.** That decides who gets the click, and it
  is the only pointer arbitration in the reader.
- **A face copied by value cannot report a count that grows.** The live count
  is on the `Set` behind it.

**The keyboard**
- **What is right for a chord is wrong for a letter.** Chords fold case;
  `gt`/`gT` are read as codepoints.
- **A binding drawn beside a command is a claim about the keyboard.** Parse
  it back through `keyspec` and ask the live keymap who owns the key.
- **Rename a field the day a second meaning arrives.**
- **Add a variant to an exhaustive enum in the commit that answers it**, or
  split before the enum grows. A split after it grows does not build.

**The page**
- **A colour drawn on the page cannot come from the theme.** The page is the
  document's, and white on white is nothing.
- **A box is where a mark is, not what it is.** Bounds answer visibility and
  order; a click asks `Mark.hits`.
- **A plan that names a file for drawing is naming a pipeline.** Check the
  pipeline is there. Anything under the pointer this frame goes through the
  overlay.
- **A heuristic that cannot fire is worse than none.** When a rule is about
  what a format can contain, check what it can contain.
- **Print the numbers before choosing a threshold.**

**Checking your work**
- **A registry is not usable until something prints it**, in the same
  commit. `fenrir icons` found five bad entries in its first minute.
- **Draw the thing before committing it.** Twenty-eight icons passed their
  tests and two were unreadable at 16px; an ASCII raster in a throwaway test
  showed it.
- **A ranking is the half a picture cannot check.** That is what
  `fenrir commands --match` is for.
- **An icon has to differ from the one beside it.** Shoot the rail whenever a
  button is added.
- **Run the other theme.** A colour literal outlives the file that replaced
  it.
- **Background work has to be stood still to be photographed.** Seed the
  results before the window opens.
- **A shot runs with no plugins and no open popups**, so open them by hand.
  **Shoot against a scratch `--db`**, because marks changed during a shot are
  written.
- **Verify a parser through what uses it, then commit the parser first.**
- **Take the suspect out and measure again.** The diff for ink does nothing
  without ink; removing a button found the cost.
- **A table is written one entry a line**, so a column can be read down.

**Estimating and committing**
- **Estimate the file, not the feature.** A new file is about 400 lines: a
  third documentation, a third tests, a third code. Count one file per format
  the commit must understand, and a registry as a file.
- **Seams that work:**
  - the model before the widget that draws it;
  - the keyboard after the mouse;
  - a forward-looking change split off in front;
  - failing those, the seam that compiles.

  A commit that draws nothing is bookkeeping, not a seam.
- **Commits are 300–700 lines** (`CLAUDE.md`), and plans should be made to
  that.

## Verifying a change

```
zig build test                          # green before committing
zig build -Doptimize=ReleaseSafe
zig build -Dsqlite=false -Dlua=false    # compiles; its tests skip cleanly
zig build -Dtarget=x86_64-linux-gnu     # if Lyngvi or the build changed

fenrir ui --out ui.png [--atlas a.png]  # the whole stack, no GPU
fenrir read F --shot s.png --path cpu   # the reader's frame, no display (no chrome)
fenrir read F --shot s.png --device     # what the GPU drew, read back

fenrir icons [--out sheet.png]          # every icon, and whether it draws
fenrir commands [--match QUERY]         # every : command, and how it ranks
fenrir trace F --text | --lines         # the page as words, with or without geometry
fenrir trace F --all --find Q           # every match and its boxes
fenrir marks F [--db D]                 # every mark as stored
fenrir marks F --ink P X Y X Y ...      # seed a stroke for a shot
fenrir health | plugins [--api]         # what the build has; what a configuration did
fenrir run S.lua F.pdf                  # a plugin over a document, no window
```

Tests go where no window, device or font is needed: Þviti's solver, `keys`,
`Layout`, `Marks`, the parsers.

**A shot cannot open a popup.** Add two lines at the top of the session
(`menu.show(…)`, `settings.show()`, `showPalette()`, or `startPlugins` without
its `shot == null`), take a `--device` shot, and remove them before
committing.

**Performance is part of the contract.** Chrome draws every frame. Measure
`fenrir read F --frames 1200 --vsync off` interleaved against the previous
commit's binary, best of five or more. `draw.Renderer`'s `boxes_drawn` and
`glyphs_drawn` show whether a panel is rebuilding an off-screen list.
`fenrir raster F --all --stats` must not move.
