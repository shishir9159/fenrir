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

### Phase 10 — comparing documents ✅

After [diff-pdf](https://github.com/vslavik/diff-pdf): its options, the
defaults its users reach for (`--per-page-pixel-tolerance 10`,
`--channel-tolerance 0`, `--skip-identical`) and its exit codes (0 the same,
1 different, 2 bad arguments, 3 unreadable). `fenrir diff A B` opens the two
side by side at the first change; `--report` prints and exits.

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | a page's hash, over what its objects hold: `fenrir trace --hash` | `gelgja/DisplayList.zig`, `src/vanagandr/digest.zig`, `trace.zig` | 490 |
| ✅ | `fenrir diff --report`: pages by display list, then by pixel | `src/vanagandr/diff.zig`, `main.zig`, `Context.zig` | 766 |
| ✅ | changed regions, and the pictures diff-pdf writes | `diff.zig` | 499 |
| ✅ | two documents side by side, scrolled together, changes washed | `read.zig`, `keys.zig`, `commands.zig`, `diff.zig` | 563 |
| ✅ | gd: side by side, the overlay, and each document alone to blink | `read.zig`, `keys.zig`, `commands.zig` | 344 |
| ✅ | nudging one document against the other, and comparing again | `read.zig`, `diff.zig`, `keys.zig` | 496 |
| ✅ | a word diff over the text, and pages paired by it | `src/hlidskjalf/diff.zig`, `diff.zig` | 511 |
| ✅ | the changes panel: a row a differing page, on the right rail | `rails.zig`, `read.zig`, `tyr/backend/icons.zig` | 90 |

- **Cheap first, pixels last.** Pages pair by number, or by text with
  `--pair text`. A page with no partner is never drawn. Equal display-list
  hashes are identical pages and are never drawn. The rest are drawn at
  `--dpi 150` and compared sixteen pixels at a time over the union of the two
  pages, in eight-bit levels, so a float wobble is no difference.
- **The hash digests what an object holds, never its number.** A file
  revised in place keeps a figure's number and replaces the figure, and two
  exports number one font apart. `digest.zig` hashes each object with every
  reference replaced by its target's digest, streams undecoded. A font or
  shading with no object behind it makes the hash null, and the page is
  drawn. `trace --hash` prints what `diff` compares.
- **Regions** are the differing pixels' 16×16 tiles. A tile is one chunk of
  a row, so marking one costs nothing past the chunk's mask. Tiles one empty
  tile apart are one region, and overlapping boxes merge. A tile is under
  eight points at 150 dpi, so a reworded sentence that wraps is one region.
- **`--output-diff DIR`** writes diff-pdf's picture as PNGs named
  `a3-b3.png` and `b7.png`: ink only in the first document red, only in the
  second blue, shared dark. `--grayscale` and `--mark-differences` are
  diff-pdf's.
- **The view is the reader.** `diff` hands its view options and a
  `Comparison` to `read.runWith`; buffer 0 is the first document and buffer
  1 the second. The two windows are held together by comparing where each
  was last frame, not by hooking every scroll: the one that moved leads, and
  the other goes to its page's partner. A page one document has alone is
  shown in that document's window, which then leads.
- **`gd` and `gD`** go round side by side, the overlay, the first alone and
  the second alone. `gD` from the second is the first, so `gd gD` blinks at
  one place. The overlay is drawn on the rasterising thread at the window's
  zoom and shown as a texture on either backend.
- **`<C-arrows>`** move the second document a point; `:diff offset X Y` and
  `--offset X,Y` set it exactly. The comparison runs again on a thread of its
  own, on every core, and a nudge that arrives meanwhile restarts it when it
  returns. The overlay moves at once and the washes when the results come
  back. Pages whose hashes match stay identical at any offset.
- **Words.** A differing pair's text goes through Myers' diff
  (`hlidskjalf/diff.zig`), with the common head and tail cut first and a cap
  of 2,000 edits. Removed words are washed red on the first page and added
  ones green on the second, and the first change is the report's and the
  panel's text: `"fox" → "cat"`. `--pair text` is the same diff over hashes
  of whole pages.
- **Budget.** `diff X X --report` on the 155-page *Nanite* drew nothing and
  took 124 ms. On two unrelated 13-page papers, comparing took 94 ms beside
  4.12 s of drawing, the word diff included, and hashing 8 ms beside 52 ms of
  interpreting. The planned early stop at the tolerance was not built: it
  would shorten 2% of a pair. `read --frames 1200` was 748 ms before the view
  and 749 ms after, and `raster --all` hashed the same.
- **Not taken from diff-pdf:** a PDF of the differences (fenrir writes no
  PDF yet) and the 300 dpi default.

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
| 10 | 5, 2,450 | 8, 3,759 | 470 | a view over work is a layout, its modes, a thread and a panel: a commit each |

### Open gaps

- **Every tooltip is drawn in boxes.** `Chrome.tips` is the last thing built
  in a frame (`read.zig`, after the palette), outside every `pushStyle`.
  `tooltips` pushes a size and a background and nothing else, so its text
  takes the root style, which `UI.begin` resets to `.{}`: font 0,
  `Fonts.fallback_font`, Týr's box-drawing stand-in. Every other piece of
  chrome pushes `Chrome.face` first. The rails call `hint` inside their
  scope, but the tip is drawn after the scope has closed. The same gap
  gives the tooltip the default colours, so it ignores the light theme.
  - **The fix is in Þviti, not at the call site.** `Tips` gains `font`, `fg`
    and `bg`. `hint` copies them from `ui.style()`, the scope the control
    was built in, and `tooltips` pushes them. `sig.box.style` is the wrong
    source, because an icon button's own font is the icon face.
  - One fix covers the rails, the `fenrir ui` demo and a plugin's button,
    since each tooltip carries the look of the place that asked for it.
  - The test: build the rail under a pushed face and check the tip's
    `style.font`. It fails today. About 30 lines, and nothing per frame,
    because `hint` returns at once unless the pointer is resting.
- **`--shot --path cpu` draws no chrome.** `CpuTextures.sample` cannot sample
  the single-channel atlas. Fixing it is about 35 lines: an atlas branch there,
  and a `Chrome` in `shoot`.
- **The rails do not turn off.** Fixing it takes a setting, two bools in
  `windowRect`, and a `:set` name, about 80 lines, in whichever phase next
  touches settings.
- **`fenrir diff` compares before the window opens,** with nothing on screen.
  Two long documents with `--jobs 1` sit for seconds. The fix is the rerun
  thread started at open, with the view filling in as pairs come back.
- **The overlay is the first document's pages.** A page only the second has
  is not in them; `gD` shows it alone.

### Phase 11 — marks you can step through

| | Commit | Files | ~ |
|---|---|---|---|
| ✅ | `]a and ]c: the next mark, and the next comment` | `keys.zig`, `Marks.zig`, `commands.zig`, `read.zig` | 318 |
| | underline, strike-through and squiggle as mark styles | `Marks.zig`, `mimir/Library.zig` schema v4, `keys.zig`, `read.zig` | 500 |
| | the annotations panel filters, and `]a` follows it | `panels.zig`, `read.zig` | 350 |

- **`]` and `[` are a third prefix**, completed from typed text like `g`.
  `]a`/`[a` go to the next/previous mark of any kind and `]c`/`[c` to the
  next/previous comment, in normal and edit mode. Draw mode keeps `[`/`]` for
  the pen. `:mnext`, `:mprevious`, `:cnext` and `:cprevious` do the same.
- **Where a jump starts.** In normal mode:
  1. from the mark it last landed on, while the caret has not moved;
  2. otherwise from the caret;
  3. otherwise from the top of the page.

  In edit mode it starts from the mark in hand. Ink has no text for the caret
  to land on, so without the first rule a jump from a stroke finds the same
  stroke again. The status line reads `comment 2/5: <note>` or `mark 3/9`,
  and says when a jump wraps round.
- **Styles are PDF's four text-markup subtypes** (Highlight, Underline,
  StrikeOut, Squiggly), so writing them into a PDF (phase 13) maps one to one.
  - In visual mode `_` underlines, `-` strikes through and `~` squiggles; `m`
    still highlights. In edit mode the same keys restyle the mark in hand.
  - Underline and strike-through are one rect each. The squiggle is ink's
    disc stamping along a sine.
- **The filter** selects by colour, style, kind, `#tag` in a comment, and
  "has a comment". `]a` walks what the panel shows, so filtering to
  `#question` makes `]a` step through the questions.

---

## Comments and the canvas

LiquidText was built for a touch screen. This is for a keyboard and a mouse,
and for people who read in order to work: researchers, educators and
students. Touch can come later, because `Session.apply` takes commands, not
keystrokes.

A PDF is shared by sending it, so the comments, their links and the canvas
are written into the file. The same file opened on another machine shows the
same canvas, and other readers still show the comments.

**Already decided.**
- `Layout`'s leaf is a `Pane` union (phase 5), so a canvas is another
  variant, not a second layout system.
- Panels are overlays, so a canvas pane does not compete with them.
- Anything shown from a page is a clipped replay of the `Scene` that
  `Recorded` in `read.zig` caches.
- New Mímir tables take an `id INTEGER PRIMARY KEY`, and name documents by
  `path` and by the file's trailer `/ID`. A path changes when a file is
  moved or sent; the `/ID` does not.

### The model

- **Every node is a comment.** There are no free-standing cards and no
  groups. Every thought on the canvas is about something in a document, and
  can always be traced back to it.
- **A comment is made on a selection.** Select with `v`, `V`, a drag, or
  `<C-v>` for a rectangle; press `c`; type. The selection becomes the
  comment's **anchor**. The anchor is highlighted by default, or marked with
  an arrow when the `comment_anchor` setting is `arrow`, for readers who want
  no colour on the text.
- **One anchor, many comments.** Each comment is its own node, and all of
  them tie back to the same anchor. `c` on an anchor in edit mode adds
  another.
- **A comment may carry an image.** Either a snip of a page, replayed from
  the recorded scene and so sharp at any zoom, or an image file.
- **Comments link to comments.** A link is two comments and an optional label
  (`supports`, `contradicts`). There is no other kind of node to link.

### Where it is stored

**In the PDF.** A document is shared by sending the file, so the file holds
its anchors, comments, links and canvas. The library journals each change as
it settles, and the PDF takes them as one incremental update on `:w` and on
close. `:set store=library` keeps a document's marks out of its file; the
setting and each document's choice are kept in the library.

| | in the PDF | other readers |
|---|---|---|
| anchor | `/Highlight`, `/Underline`, `/StrikeOut`, `/Squiggly` or `/Ink`; an arrow is a `/Line` with an arrowhead | draw it |
| its first comment | the anchor's own `/Contents` | show it as the anchor's note |
| more comments | a `/Text` annotation replying to the anchor through `/IRT` | show a thread |
| an image comment | a `/Stamp` replying to the anchor, the image its appearance | draw it |
| cards and links | fenrir's page data, under `/PieceInfo` on the anchor's page | keep it, and do not read it |
| a link to another file | the same, naming the other file by its `/ID` | keep it, and do not read it |
| camera, scroll, folds, the docked canvas | nothing: these are the library's | — |

- **The first comment is the anchor's `/Contents`**, as Acrobat and Zotero
  write a highlight's note. Most anchors carry one comment, and it costs them
  no annotation of its own.
- **Where you are looking never changes the file.** Panning the canvas and
  scrolling are the library's, so a document that is only read is never
  written.

**Fenrir's page data.** ISO 32000 (§14.5) gives an application a place for
data other programs keep and do not read: a page's `/PieceInfo`, under the
application's name. Each page with cards on it carries:

```
/PieceInfo << /Fenrir 812 0 R >>  /LastModified (D:…)    on the page, once
812 0 obj << /LastModified (D:…) /Private (…) >>         the page's cards
```

- **A string, not a stream.** A string can go into the save's object stream
  and be compressed with everything else the save writes. A stream is an
  object of its own, with a dictionary and a cross-reference entry, and
  cannot.
- **Moving a card rewrites that one object.** The page names it and does not
  change. The page's `/LastModified` is written when `/PieceInfo` first is,
  because the standard requires the one with the other.

The string is a version byte and three sections, each a count and then its
entries. Integers are LEB128 and signed ones zig-zagged. In the literal
string only `\`, `(`, `)` and CR are escaped.

| Section | Each entry |
|---|---|
| documents | the 16 bytes of another file's `/ID`, and its file name |
| cards, by id | the id, as a step from the last; x and y in whole points, as steps; the width (0 is the default) and height; a byte of swatch and flags; a `/NM` string, for another program's annotation only |
| links, by from and to | from, as a step; to; a byte of swatch, arrowheads, "has a label" and "elsewhere"; the label and the document, when the byte says so |

- A card lives on its anchor's page, and a link with its first card.
- **What can be worked out is not stored.** A link's route, and the sides it
  leaves and arrives by, are the router's.
- **A card's size is stored, not measured.** Measured, it would be a
  different height on a machine with a different face, and overlap the card
  below it.
- About 7 bytes a card and 4 a link, before compression.

**Identity is `/NM`, never an object number.** A program that rewrites a
file renumbers every object and keeps `/NM`.
- Fenrir's `/NM` is `f` and a base-36 number, and the page data holds only
  the number. The next is one past the highest in the file, so two people
  annotating a file in turn never repeat one.
- Journal rows replayed onto a newer copy of the file are renumbered where
  they collide.
- Another program's annotation keeps its own `/NM`. One without is given one
  the first time it is linked, which rewrites it once.

**Keeping each save small.** Every save is appended, and nothing fenrir
wrote is ever cut or replaced, so the file keeps each save as a revision.
What a save appends is the whole cost, and it is only what changed.
- A save with nothing changed writes nothing, and closing an unchanged
  document leaves its file alone.
- One object stream and a cross-reference stream a save, when the file is
  PDF 1.5 or later, so every dictionary the save writes is compressed
  together. An older file gets a classic table. A file's version is never
  raised to save bytes.
- The first write to a page makes its `/Annots` an indirect array, so a later
  save rewrites a list and not the page.
- Defaults are left out: `/RT /R`, a zero `/F`, a card at the default width,
  a link with no label.
- Numbers are written in the fewest digits that hold them to 1/100 point.
- `/Contents` is PDFDocEncoding when every character has a byte there, and
  UTF-16BE otherwise.

**Appearances are shared wherever the drawing is.** Other readers draw only
`/AP`, so everything carries one, but:
- a comment's note icon is one form per colour, named by every comment in it;
- a mark of one rectangle has a unit square per colour and style, which the
  reader stretches to the annotation's `/Rect` (§12.5.5);
- only a mark of several lines, and ink, has an appearance of its own. It is
  left unfiltered below about 100 bytes, where zlib's header and checksum
  cost more than they save, and all of them name one shared `/Resources`
  holding the multiply blend.

**Images are copied, not encoded again.**
- A JPEG goes in as its bytes, under `/DCTDecode`.
- A PNG with no alpha and no interlacing goes in as its IDAT, under
  `/FlateDecode` with the PNG predictor, which PDF has.
- A PNG with alpha is decoded, to split out the `/SMask`.
- Two images with the same bytes are one object, found by hash.
- **A snip stays vector.** One form per snipped page holds that page's
  content once and uses the page's own resources, and each snip's `/Stamp`
  clips it. Ten snips from one page cost one copy.

**Keeping it right.**
- **What no longer matches is dropped quietly, then said once.** A card
  whose annotation was deleted in another reader is not drawn, and neither
  are its links; they are pruned the next time their page is written. The
  status line says `2 links lost their comments`. An annotation with no card
  is placed by the placement rule.
- **What fenrir cannot read is kept, never rewritten.** Page data with a
  newer version byte stays as it is, and its cards are read-only.
- **Another program's save is found before fenrir writes.** Fenrir records
  the length and `startxref` it read. If the file changed on disk (a second
  reader, a sync client), it reads it again, applies the journal by `/NM`,
  and appends to what is there now. It never appends to bytes it has not
  parsed.
- **A write that fails keeps the journal.** Acrobat holding the file open on
  Windows, a read-only folder, a full disk: the change stays in the library,
  the status line says so, and the next `:w` or close tries again.
- **A torn append is repaired.** Before appending, the library records the
  file's length and the length it will have. A record still there at the
  next open means the reader died writing:
  - at the new length the save finished, and the record is cleared;
  - between the two it was torn, and fenrir cuts the file back to the old
    length and saves again;
  - anything else is not fenrir's tail, and is left alone with a message.
- **A stripped canvas comes back, on this machine.** A program that rewrites
  a whole file may drop what it does not understand, `/PieceInfo` included.
  The comments survive as annotations. The library keeps the page data it
  last wrote, keyed by `/ID` and `/NM`, and puts the cards and links back
  where the ids still match. On another machine they are gone, and the
  comments remain.
- **Links across documents travel with the file that holds their first
  card**, naming the other by the first half of its `/ID`, which a revision
  keeps, and by its file name. On open, the `/ID` is looked up in the
  library, then by name in the file's own folder, and checked. A link whose
  document is not found is drawn as a stub naming it. A file with no `/ID`
  is given one by fenrir's first save. So a folder of papers sent together
  keeps its links.
- **The library is the journal.** A reader killed before a save loses
  nothing: the next open applies the unwritten rows again and says so, and
  the next save writes them.
- **When the PDF is not written**, the library is used and the status line
  says why:
  - the file is encrypted (not supported yet);
  - DocMDP (`/Perms`) forbids changes, at P=1 or P=2;
  - it is signed at P=3, which permits annotations and not pages: the
    anchors and comments are written, and the page data stays in the
    library;
  - it is read-only or locked.
- **An incremental update, not a rewrite.** New and changed objects are
  appended after `%%EOF` with their own cross-reference section and `/Prev`.
  The original bytes stay untouched, and a signature over an earlier
  revision stays valid.
- **Everything fenrir writes carries:**
  - `/NM`, its identity in links;
  - `/T`, the `author` setting;
  - `/M`, when it was changed;
  - an `/AP` appearance stream, because other readers draw only that.
- **Reading `/Annots` back is the other half.** Comments made in Acrobat or
  Zotero become fenrir comments, with `/IRT` threads kept and a markup's
  `/Contents` as its first comment.
- **Not settled on paper:** a reply's `/F` flags and its `/Rect`. Open a
  file fenrir wrote in Acrobat, pdf.js and Zotero, and set them by what each
  shows.

### The arrangement

The PDF is always centred in its pane.

- **Canvas off (the default).** Comments are cards in the side margins beside
  their anchors, stacked so that none overlaps, scrolling with the page. When
  a margin is narrower than a card, the tab at the anchor's corner stays.
- **`gc`** splits the window. The PDF moves to the left pane, still centred
  in it, and the canvas takes the right, with its own pan and zoom.
  `:canvas left|right|off` sets it directly, and the divider drags like any
  other.
- A leader line runs from each card to its anchor, crossing the divider when
  both are on screen.

### What to take, and from where

From LiquidText, adapted to a keyboard and a mouse:

| LiquidText | here |
|---|---|
| comments tied to passages | the model above |
| excerpts dragged out of the page | a comment carrying a snip of its anchor |
| pinching a document to bring distant passages together | folds: `zM`, `zR`, `zf` |
| gestures | keys and the mouse |

From Obsidian Canvas, including what it lacks without plugins:

| Obsidian Canvas | here |
|---|---|
| nodes, labelled edges, colours | comments, links, the eight swatches |
| mostly mouse-driven | `hjkl` moves to the nearest card in that direction |
| a card copied from a PDF forgets where it came from | every comment has an anchor |
| no automatic layout | `:arrange` |
| no linear export | Markdown, in reading order |
| slows with hundreds of cards | the instance pipeline, culled against the camera |
| the JSON Canvas file | an export (phase 17), never the store: it would be a second file beside a document that can hold the data, and its vocabulary has no anchors |

Who each part is for:
- **Researchers:** comments across papers linked into an argument, tags, a
  diff between revisions (phase 10), and export with page citations.
- **Educators:** snips and comments exported as handouts, ink, and arrange.
- **Students:** `]c` to review, folds to reread only what was marked,
  `#question` tags, and flashcards as a plugin.

### Phase 12 — comments as their own records

| Commit | Files | ~ |
|---|---|---|
| comments and links in mímir, many to an anchor, named by /NM | `mimir/Library.zig` schema v5, `vanagandr/library.zig` | 550 |
| a comment made on a selection with c | `Marks.zig`, `keys.zig`, `read.zig` | 450 |
| the arrow anchor, as a setting | `settings.zig`, `read.zig` | 300 |

- **The ids the PDF will hold, from the first commit.** A comment row
  carries its `/NM`, and a document its trailer `/ID` beside its path, so the
  library and the PDF never translate one id into another. A link row names
  its two comments by `/NM`, and the other document by `/ID`.
- A mark's `note` migrates into its first `comment` row. `fenrir marks`
  prints the comments and links.
- In visual mode, `c` makes the anchor and opens a comment. In edit mode, `c`
  adds another comment to the mark in hand, and `a` edits the comment in
  hand.
- `]c` now walks each comment rather than each anchor.
- Plugins: `fenrir.comments()` and `fenrir.comment{anchor, text}` under the
  document capabilities, and `CommentAdd`/`Remove`/`Change` events.

### Phase 13 — comments in the PDF

Before the canvas, so that every later phase lands with its PDF form rather
than having one retrofitted under it.

| Commit | Files | ~ |
|---|---|---|
| annotations read back as marks and comments | `src/gjoll/annots.zig`, `read.zig` | 550 |
| an incremental update, as bytes | `src/gjoll/Writer.zig` | 650 |
| appearances, shared wherever the drawing is | `gjoll/annots.zig` | 450 |
| the journal, :w and close, and when the pdf is refused | `mimir/Library.zig`, `settings.zig`, `commands.zig`, `read.zig` | 550 |
| marks moved between the stores, and what each save cost | `vanagandr/library.zig` | 350 |

- **Reading:** `/Highlight`, `/Underline`, `/StrikeOut`, `/Squiggly`,
  `/Ink`, `/Line`, `/Text`, `/Stamp` and `/FreeText`. An `/IRT` thread becomes
  the comments on one anchor, a markup's `/Contents` is its first comment,
  and `/NM` is each annotation's identity.
- **Writing:** `Writer` returns bytes and the CLI appends them, because the
  library layer opens no files. It writes:
  - one object stream and a cross-reference stream, or a classic table for a
    file older than PDF 1.5;
  - `/Prev`, and `/ID`, keeping the first half or making one;
  - free entries for what was deleted.

  `DocSave`, reserved in phase 8, fires.
- **A saved file is checked by what reads it.** Gjöll opens every file the
  writer makes, and `trace --all --hash` is the same before and after: a save
  adds annotations and changes no page.
- **Moving a document:** `fenrir marks F --store pdf` moves its marks into the
  PDF. `--store library` moves them out, with an update that drops them from
  `/Annots`. The round trip gives back the same rows.
- **`fenrir marks F --bytes`** prints each revision fenrir appended, its
  size, and what is in it. It is the check on "Keeping each save small".

### Phase 14 — the canvas pane and the margins

| Commit | Files | ~ |
|---|---|---|
| a canvas model: cards on a plane, a camera, a hit test | `src/hlidskjalf/Canvas.zig` | 450 |
| cards as page data, a few bytes each, under /PieceInfo | `src/hlidskjalf/pagedata.zig`, `gjoll/annots.zig` | 450 |
| the canvas beside the document, on gc | `Layout.zig` (`Pane.canvas`), `read.zig` | 450 |
| moving about a canvas from the keyboard | `keys.zig`, `Canvas.zig`, `read.zig` | 400 |
| a text field over several lines, for comments | `thviti/widgets/field.zig` | 450 |
| leader lines, and following either way | `Canvas.zig`, `read.zig` | 350 |
| comments in the margins of a centred page | `Canvas.zig`, `read.zig` | 400 |

- **Keys in the canvas pane:**
  - `hjkl` selects the nearest card in that direction, and `HJKL` moves it;
  - enter edits the card, `o` goes to its anchor, `x` deletes it;
  - `0` fits every card, and `+`/`-` zoom.

  With the mouse, drag a card to move it, or drag with the middle button to
  pan.
- **Following.** Clicking a card scrolls the PDF to its anchor, and `]c` in
  the PDF pans the canvas to the card. `:canvas follow` toggles it.
- **Placement.** A new card goes beside the previous card from the same page,
  or else at the first free spot near the camera's centre. It never lands on
  another card. Positions snap to whole points, which is what the page data
  holds.
- **Page data is bytes to Gjöll.** Gjöll hands each page's `/Fenrir` string
  up and takes one back, and does not know what a card is. `pagedata.zig` is
  the encoding, bytes in and cards out, tested by round trip and on every
  truncation of a valid string. Its first version already has the links and
  documents sections, empty, so phase 15 does not change the format.

### Phase 15 — links

| Commit | Files | ~ |
|---|---|---|
| links between comments, drawn and stored | `Canvas.zig`, `pagedata.zig`, `Library.zig`, `read.zig` | 500 |
| labels on links, and `:arrange` | `Canvas.zig`, `read.zig` | 400 |
| links across documents, by the other file's /ID | `pagedata.zig`, `Library.zig`, `read.zig` | 400 |

- To link two comments, press `L` on a card, move to the target with `hjkl`,
  and press enter; or drag from a card's edge to the other card.
- **To link across documents**, open both, press `L` on a card, move to the
  other document's canvas as between any two windows, and press enter. The
  link is stored with its first card, and found again as "Where it is
  stored" says.
- **Links are orthogonal**: horizontal and vertical runs with rounded elbows,
  three rect instances each. The instance pipeline does not rotate, and a
  capsule primitive is a shader change no profile has asked for.
- `:arrange reading` lays cards out in their anchors' reading order;
  `:arrange column` and `:arrange grid` are the other two.

### Phase 16 — images in comments

| Commit | Files | ~ |
|---|---|---|
| a rectangle selection, on ctrl-v | `View.zig`, `keys.zig`, `read.zig` | 350 |
| a snip of the page in a comment | `Canvas.zig`, `read.zig`, `gjoll/annots.zig` | 500 |
| a png decoder, and an image file in a comment | `gleipnir/png.zig`, `read.zig` | 400 |

- `<C-v>` is Vim's visual block, and on a page a block is a rectangle: a
  figure, an equation, a table. `m` highlights the area and `c` comments on
  it.
- **A snip is the anchor's rectangle replayed from the recorded `Scene`**:
  vector, sharp at any zoom, never re-interpreted. Stored in a PDF it is
  still vector: the page's own content, clipped (see "Images are copied, not
  encoded again").
- **Image files:** JPEG goes through `gjoll/filter/jpeg.zig`. PNG needs a
  decoder of about 250 lines on `std.compress.flate` and
  `filter/predictor.zig`, which is the real need "recommended against" said
  to wait for. In a PDF the file's bytes are copied, not encoded again.

### Phase 17 — getting work out

| Commit | Files | ~ |
|---|---|---|
| searching comments, on / in the canvas | `Canvas.zig`, `find.zig` | 250 |
| comments as markdown, in reading order | `src/vanagandr/canvas.zig` | 450 |
| the canvas as a json canvas file, for obsidian | `vanagandr/canvas.zig` | 300 |
| folds: a document reduced to its marks | `View.zig`, `keys.zig`, `read.zig` | 450 |
| comments and links for plugins | `galdr/Runtime.zig`, `Host.zig` | 350 |

- **`fenrir canvas F --export md [--images DIR]`** writes:
  - a heading per document;
  - anchors in reading order, each quoted with (title, p. N);
  - each anchor's comments beneath it;
  - links as references;
  - snips as PNGs, through the existing writer.
- **`fenrir canvas F --export canvas`** writes JSON Canvas 1.0, for Obsidian:
  a text node per comment quoting its anchor with (title, p. N), an edge per
  link with its label, and the positions and sizes the page data holds. It
  is a copy going out, and is never read back.
- **Folds are LiquidText's collapse, done with keys.**
  - `zM` shows only the anchored passages, stacked as clipped replays in
    reading order.
  - `zR` opens everything again.
  - `zf` folds a selected range away, and `zo`/`zc` open and close one fold.
- **Plugins** get `link{}` and `LinkAdd`/`LinkRemove` events: enough for a
  flashcard plugin to turn `#question` comments into cards.

### Canvas performance rules

- Cards are culled against the camera before a box is built, as `list.zig`
  culls rows.
- Canvas text sizes are quantised to eighth-octave steps, so zooming does not
  fill the atlas with every size. Below about 6px, a card's text is drawn as
  grey bars.
- On the GPU a snip is a matrix and a clip on the recorded scene. On the CPU
  only visible snips are rasterised, on the worker thread, and they stay
  blank until ready, as pages do.
- A card's layout is rebuilt when its text changes, and link routes when a
  card moves. Nothing is rebuilt per frame.
- **Budget:** seed 1,000 comments and 1,000 links with `fenrir run`, dock the
  canvas, and `read --frames 1200 --vsync off` must stay within noise of the
  reader without the canvas.
- **Size budget**, read off `fenrir marks F --bytes`:
  - the page data of 1,000 cards and 1,000 links over 100 pages is at most
    16 KB;
  - moving one card and saving appends at most 512 bytes;
  - a save with nothing changed appends nothing.

  These are ceilings from an estimate. Print the real numbers, then tighten
  them.

**Not in these phases:**
- presenting a canvas as a path, for lectures;
- the clipboard, for copying a comment with its citation (Lyngvi has none);
- maths in comments;
- touch;
- merging two copies of a file annotated in parallel. Their `/NM`s may
  collide, and a merge would renumber one side;
- `--compact`, a rewrite that drops superseded revisions. It is a
  whole-file writer that breaks signatures, and the size budget keeps what
  each save appends small enough to wait for it.

## Recommended against

- **WebP icons.** Thousands of lines of codec for what `.path` and `.glyph`
  do better.
- **Full inline SVG.** The `d=` subset covers every icon set worth having.
  Groups, transforms, gradients and CSS would be a second document format.
- **PNG icons.** The PNG decoder arrives with phase 16, for images in
  comments. `.path` and `.glyph` still do icons better at every size.
- **A sidecar file as the store** (`paper.pdf.fenrir`, or a JSON Canvas
  file). There would be two files to send, and one gets lost.
- **Canvas data as private keys on each annotation.** Moving a card would
  rewrite its whole annotation, and every link would repeat a comment's name.
  Page data costs a few bytes a card, and a move rewrites one string.
- **Rewriting the whole file to keep it small.** It renumbers every object
  and breaks a signature over an earlier revision. Every save appends, and
  the rules in "Where it is stored" keep what it appends small.
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
- **What a thread will hand over is allocated where a thread can free it.**
  The command's arena is not thread-safe, so a comparison's results are
  `smp_allocator`'s from the start, and the one made again after a nudge
  replaces them in kind.

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
- **Whatever is built at the end of the frame is outside every scope.** It
  gets the root style: font 0, which is Týr's boxes, and the default
  colours. A tooltip recorded inside the rail and drawn after it has to
  carry the rail's look with it.
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
- **A held key is a request a frame.** Work it starts is restarted when the
  running one returns, not once per repeat: a nudge held for a second is one
  comparison behind, never thirty.
- **Rename a field the day a second meaning arrives.**
- **Add a variant to an exhaustive enum in the commit that answers it**, or
  split before the enum grows. A split after it grows does not build.

**The page**
- **A colour drawn on the page cannot come from the theme.** The page is the
  document's, and white on white is nothing.
- **Hold two windows together by comparing them, not by hooking them.** A
  window moves by key, wheel, scrollbar, jump, fit and resize. Asking each
  frame which one moved catches all six, including the one nobody listed.
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
- **A hash that lets work be skipped may be wrong in one direction only.**
  Hash what is drawn, digest objects by content, and return nothing rather
  than guess. Two pages that hash apart cost a render; two that wrongly hash
  alike report a changed page as identical.
- **Measure the plan's optimisation before building it.** The early stop at
  the pixel tolerance would have shortened 2% of a pair.
- **Send stdout and stderr to two files.** On this machine `> f 2>&1` has
  lost a report's lines under the timing line, twice.

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
fenrir marks F --store pdf|library      # move a document's marks between stores
fenrir marks F --bytes                  # each revision fenrir appended, and what is in it
fenrir health | plugins [--api]         # what the build has; what a configuration did
fenrir run S.lua F.pdf                  # a plugin over a document, no window
fenrir trace F --all --hash             # each page's hash, which diff compares
fenrir diff A B --report [--pair text]  # the pages that differ, and the words
fenrir diff A B --output-diff DIR       # diff-pdf's pictures, as PNGs
fenrir diff A B --shot s.png --path cpu # the comparison view, no display
```

Tests go where no window, device or font is needed: Þviti's solver, `keys`,
`Layout`, `Marks`, the parsers.

**A saved PDF is checked by what reads it.** Write to a copy, never the only
one, and:
- open it again with Gjöll;
- compare `trace --all --hash` before and after, because a save adds
  annotations and must change no page;
- run `--store pdf` then `--store library`, and check the same rows come back;
- open it once in another reader, to see the comments and the threads.

**A shot cannot open a popup.** Add two lines at the top of the session
(`menu.show(…)`, `settings.show()`, `showPalette()`, or `startPlugins` without
its `shot == null`), take a `--device` shot, and remove them before
committing.

**Performance is part of the contract.** Chrome draws every frame. Measure
`fenrir read F --frames 1200 --vsync off` interleaved against the previous
commit's binary, best of five or more. `draw.Renderer`'s `boxes_drawn` and
`glyphs_drawn` show whether a panel is rebuilding an off-screen list.
`fenrir raster F --all --stats` must not move.
