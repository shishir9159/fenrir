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
neither of which opens a document. The README says so outright:

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
│ -- VISUAL --              fit width   138%            paper.pdf  │  status
└──────────────────────────────────────────────────────────────────┘
   ^left rail                                    ^scrollbar ^right rail
```

Left rail: normal / visual / edit / draw, then the highlight colour palette.
These **are** the existing keymap modes (`keys.Mode`), not a parallel concept
— a rail button sends the same `Command` the key does. Right rail: panel
toggles at the top, the page counter at the bottom.

Panels open as an **overlay docked to the right rail**, over the page — not as
a third column that reflows it. Reflowing would refit every `fit_width` view
on every toggle.

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

### Phase 1 — the widget set 🚧

New files under `src/thviti/widgets/`, with `widgets.zig` re-exporting them.
Each is written the way the existing ones are: `next`, `box`, `signal`, no
privileged access to anything a caller could not reach.

| | Commit | ~ |
|---|---|---|
| ✅ | the editing model behind a text field | 345 |
| ✅ | a box whose text and key are given separately | 30 |
| ✅ | a text field widget | 398 |
| ✅ | clicking and dragging in a text field | 77 |
| ✅ | a list widget that only builds its visible rows | 254 |
| 🚧 | floating popups, and menus built on them | 200 |
| | a tab bar | 180 |
| | icon buttons, tooltips and a draggable splitter | 200 |

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

The splitter commit also gives `Layout` draggable dividers, closing the
README's *"Windows are resized only by the layout, not by dragging the
divider."*

### Phase 2 — icons

Icons are **declared, never embedded**. A plugin registers
`plugin_id.icon_name`; every toolbar, menu, tab and palette entry references
that ID. Nothing outside the registry knows how an icon is drawn.

| Commit | Files | ~ |
|---|---|---|
| an icon face whose glyphs are built in | `src/tyr/backend/icons.zig` | 280 |
| the icon registry: namespaced ids and slots | `src/thviti/Icons.zig` | 250 |
| svg path data, parsed into an outline | `src/tyr/svgpath.zig` | 260 |
| icon themes, and `fenrir icons` to check them | `vanagandr/icons.zig` | 200 |

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

### Phase 3 — zoom, dark mode, settings

| Commit | ~ |
|---|---|
| fit page and fit height, beside fit width — `View.fit_width: bool` → `Fit { free, width, height, page }` | 150 |
| the zoom control in the status bar — a menu, plus `:fit width\|page\|height\|actual` | 180 |
| a light theme, and the setting that picks it — `theme` in Mímir, `:set theme=…` | 150 |
| a settings page — a panel over `Library.settings()` | 280 |

`refit` is already called by `Layout.arrange` on every rectangle change, so
all four fit modes survive splits and resizes for nothing.

### Phase 4 — the rails and the panels

| Commit | Files | ~ |
|---|---|---|
| the right rail, with the page number on it | `read.zig` | 250 |
| a panel listing the highlights and their notes | `read.zig` | 250 |
| the document outline, read out of `/Outlines` | `src/gjoll/outline.zig` | 300 |
| a bookmarks panel over the outline | `read.zig` | 200 |
| the left rail: modes and the colour palette | `read.zig` | 250 |

A "comment" in fenrir is a note on a highlight — one panel, not two. The
annotations panel is a list over `Buffer.marks.items()` sorted by
`Marks.readsBefore`; clicking a row calls `View.scrollToBox`.

**Nothing parses `/Outlines` today.** `gjoll/outline.zig` sits beside
`pages.zig` and does the same kind of job: walk `/First`/`/Next` with a depth
cap and cycle detection, read `/Title`, resolve a destination from `/Dest` or
from `/A` with `/S /GoTo` — the `[page /XYZ x y]`, `/Fit` and `/FitH` forms
and named destinations through both `/Dests` and the `/Names` name tree. It
returns a flat array with a depth per entry, which is what a tree widget wants
and what makes it testable with no window. Damage tolerance as everywhere
else: a broken outline yields no bookmarks, never an error that stops the
document opening.

### Phase 5 — tabpages

| Commit | Files | ~ |
|---|---|---|
| tab pages, each with its own split tree | `src/hlidskjalf/Tabs.zig` | 250 |
| the tab bar | `read.zig` | 180 |

A tabpage owns a `Layout`, as in Vim. `Tabs` is a list of them plus an active
index; `Session` holds a `Tabs` where it held a `Layout`. `:tabnew`,
`:tabclose`, `gt`/`gT`, `<C-w>T`.

**One forward-looking change lands here.** `Layout`'s leaf payload becomes a
`Pane` tagged union rather than a bare view index, with one variant today,
`.document`. See *Decisions taken for the canvas*.

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
| `ThemeChanged` | lands with the light theme |
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
