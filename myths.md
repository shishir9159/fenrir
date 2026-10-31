# The myth, the modules and the source

Why the modules are named as they are, what each of them is, and where
its files live. The argument for the names comes first, because the
dependency order in the second section is the whole of the design, and
the third is that same order at file granularity.

## The name

PDF is the beast: ninety-odd content-stream operators, five compression
filters, CMaps, CID fonts, encryption, JBIG2, colour spaces that carry their
own PostScript interpreter, and three decades of malformed files. MuPDF and
PDFium chain it with large C codebases. Both work; both are heavy iron.

In the myth the gods try heavy iron twice, and the wolf snaps Lœðingr and then
Drómi. What holds is **Gleipnir**, made by dwarves from six things that do not
exist: soft as silk, light enough to hold in one hand. That is the pitch —
Zig, Vulkan and compute shaders, materials that look too slight for the job,
binding the same beast.

Týr still loses the hand. That part is not optional.

## Modules

Dependencies run one way, downward. Nothing below `Document` knows documents
exist; nothing at or below it knows what a page is.

| | Directory | Role | In the myth | Status |
|---|---|---|---|---|
| **Gjöll** | `src/gjoll/` | parser: objects, xref, filters, pages, content streams, images | the boulder the fetter is anchored to | done |
| **Gelgja** | `src/gelgja/` | the display list: parser output, renderer input | the cord threaded through the rock | done |
| **Gleipnir** | `src/gleipnir/` | rasteriser: rect and path pipelines | the ribbon that holds | both pipelines, CPU and GPU |
| **Týr** | `src/tyr/` | fonts: outlines, encodings, the glyph atlas | the hand it cost | three parsers of its own |
| **Þviti** | `src/thviti/` | the interface: box tree, layout, widgets, icons | the stone that pins the fetter | core and widget set |
| **Lyngvi** | `src/lyngvi/` | platform: window, input, Vulkan device | the island it happened on | Win32 runs; Wayland compiles |
| **Mímir** | `src/mimir/` | SQLite: recent files, places, settings, marks | the well of memory | done |
| **Hliðskjálf** | `src/hlidskjalf/` | buffers, windows, tabpages, marks, the keymap | Odin's seat, from which every world is seen | done |
| **Galdr** | `src/galdr/` | sandboxed Lua 5.4 plugins | a spell that makes the world act differently | done |
| **Vánagandr** | `src/vanagandr/` | the CLI, one file per command, and the reader | "monster of the river Ván", his other name | done |

Directory and identifier names are ASCII-folded (`gjoll`, `tyr`); diacritics
live only in prose. Zig accepts UTF-8 identifiers; build systems, shells and
filesystems on three platforms are less reliable about it.

## Source layout

```
src/
  root.zig  main.zig          the library surface; the CLI's dispatch table
  gjoll/                      Gjöll
    object.zig                the 8 object types; no allocation, no ownership
    Lexer.zig  Parser.zig     bytes to tokens to objects; knows nothing of documents
    xref.zig                  both table encodings, /Prev chains, reconstruction
    Document.zig              resolution, object streams, decoded-stream cache
    pages.zig  Page.zig       the page tree walk and inheritance; one page's geometry
    outline.zig               /Outlines and their destinations
    print.zig                 objects back to readable text
    image.zig                 an image XObject decoded to samples
    filter.zig  filter/       the pipeline; ascii (hex, 85, run-length), lzw, predictor, jpeg
    content.zig  content/     the interpreter: Scanner, Interpreter, matrix, color,
                              function (types 0, 2, 3, 4), Font (widths, codes, /ToUnicode)
  gelgja/                     Gelgja: geom, paint, DisplayList, Builder, trace
  gleipnir/                   Gleipnir
    sdf.zig  rect.zig         the distance field; the 96-byte instance
    DrawList.zig              call sites, the clip and transform stacks
    software.zig  png.zig     the rect pipeline's CPU oracle, and a PNG writer
    pipeline.zig              the rect pipeline's Vulkan contract
    path.zig  stroke.zig      flattening; stroke to fill
    raster.zig  pathpipe.zig  stencil-then-cover on the CPU, and its GPU contract
    slug.zig  slugpipe.zig    analytic coverage, and its GPU contract
    scene.zig  replay.zig     a list prepared for the GPU; a list replayed onto a canvas
    shader/                   GLSL, slang/, and the committed spirv/
  tyr/                        Týr
    Face.zig  Shaper.zig      the two interfaces
    Outline.zig  format.zig   the shared outline; sniffing a font program
    registry.zig              the one place that knows which backends are built
    backend/                  truetype, cff, type1, icons, fallback; freetype, stb, harfbuzz
    encoding.zig              codes to glyph names to code points
    raster.zig  Atlas.zig     signed-area coverage; the subpixel-keyed atlas
    Fonts.zig  svgpath.zig    faces, atlas and layout together; SVG path data for icons
  thviti/                     Þviti
    key.zig  Box.zig  UI.zig  identity, the node, the tree and its solver
    input.zig  text.zig       platform input; the one adapter to Týr
    draw.zig                  the tree as Gleipnir instances
    Theme.zig  Icons.zig      colours by purpose; the icon registry
    widgets.zig  widgets/     field, list, popup, menu, tabs, tool, splitter
  lyngvi/                     Lyngvi
    vk.zig  loader.zig        Vulkan declared by hand; the loader and three dispatch tables
    spirv.zig  shaders.zig    checking a module; the compiled blobs, or why there are none
    choose.zig                every device and swapchain decision, as pure functions
    Window.zig  Events.zig    the platform interface; a message loop as one frame of input
    win32.zig  wayland.zig  wayland/  x11.zig (a stub)
    Device.zig  Swapchain.zig
    Renderer.zig  PathRenderer.zig   the rect pipeline and the analytic pipeline, on the device
  mimir/                      Mímir: Db (SQLite by hand), Library (the schema)
  hlidskjalf/                 Hliðskjálf
    Buffer.zig  View.zig      a document; a window onto one
    Layout.zig  Tabs.zig      the split tree; tabpages
    Marks.zig                 marks, their history, reading order
    keys.zig  commands.zig    the modal keymap; the : command registry
    text.zig  search.zig      where the words are; finding a string
  galdr/                      Galdr: Runtime, Host (what a plugin reaches), lua, keyspec, icons (themes)
  vanagandr/                  Vánagandr: one file per command, plus the reader's parts:
                              read, chrome, rails, panels, palette, find, settings,
                              glyphs, images, sysfont, library
```

Þviti is the only layer that imports across, in two named files: `text.zig`
reaches Týr and `draw.zig` reaches Gleipnir. `UI.zig` asks string widths
through a vtable, so the layout solver is tested with no fonts and no
renderer. Gelgja imports neither the PDF layer nor a graphics API. Týr
imports Gelgja's geometry and nothing else, and never sees a character code,
so two backends can be diffed without an encoding bug confusing the diff.
Gjöll imports Týr's three encoding tables, which are PDF's (Annex D), not a
font format's; the argument is at the top of `Font.zig`.

**Memory.** A `Document` owns the file bytes and one arena. Every `Object` it
hands out borrows from one or the other, so objects are cheap to copy and
nothing returned needs freeing. Names and strings with no escapes are slices
of the file.
