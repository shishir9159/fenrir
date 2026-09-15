# fenrir

A PDF reader written from scratch in Zig, rendering on Vulkan. No parsing
libraries, no UI toolkit, no GTK, no SDL.

## The name

PDF is the beast. Ninety-odd content-stream operators, five compression
filters, CMaps, Type0/CID fonts, encrypted streams, JBIG2, colour spaces that
carry their own PostScript interpreter, and three decades of malformed files
in the wild. MuPDF chained it with a large C codebase. PDFium chained it with
a much larger one. Both work. Both are heavy iron.

In the myth the gods try heavy iron twice. Lœðingr, the wolf snaps. Drómi,
twice as strong, he snaps that too. What finally holds is **Gleipnir** —
made by dwarves out of six things that do not exist, soft as a silk ribbon,
light enough to hold in one hand.

That is the pitch for this project. Zig and Vulkan and compute shaders
instead of a hundred thousand lines of C and a CPU scan converter: a young
systems language, a graphics API meant for games, materials that look far too
slight for the job — binding the same beast the giants bind.

Týr still loses the hand. That part is not optional.

### Components

| Name | Directory | Role | In the myth | |
| --- | --- | --- | --- | --- |
| **Fenrir** | — | the format, and this project | the wolf | |
| **Gjöll** | `src/gjoll/` | parser: objects, xref, filters, page tree, images | the boulder the fetter is anchored to | done |
| **Gelgja** | `src/gelgja/` | the display list: parser output, renderer input | the cord threaded through the rock | interface done |
| **Gleipnir** | `src/gleipnir/` | rasteriser: rect and path pipelines, Vulkan backend | the ribbon that holds | both pipelines, on the CPU and the GPU |
| **Týr** | `src/tyr/` | fonts: outlines, encodings, glyph atlas | the hand it cost | three parsers, encodings, atlas |
| **Þviti** | `src/thviti/` | the interface: box tree, layout solver, signals | the stone that pins the fetter down | core done |
| **Lyngvi** | `src/lyngvi/` | platform: window, input, Vulkan device | the island it happened on | window and device done |
| **Vánagandr** | `src/vanagandr/` | the command-line tool | "monster of the river Ván", his other name | done |

Directory and identifier names are ASCII-folded — `gjoll`, `tyr`,
`vanagandr` — and the diacritics live only in prose. Zig will accept UTF-8
identifiers; build systems, shells, and filesystems across three platforms
are less reliable about it, and this is not the hill.

**Status: a PDF opens in a window and you can read it.** `fenrir read
file.pdf` scrolls continuously through the document with the wheel, zooms,
and shows highlights, stamps and everything else a person has added to it.
`fenrir raster file.pdf --page 1` writes the same picture to a PNG. Across a
400-document corpus every glyph on every first page is accounted for: drawn,
blank, or an invisible OCR layer over a scan.

Gjöll is done: the container is fully readable, the page tree resolves into
pages with their effective geometry, and the content-stream interpreter turns
one into a display list — all seventy-three operators, with colour spaces,
functions, form XObjects, inline images, patterns and Type 3 glyphs. `fenrir
trace` prints the result.

Gleipnir has both pipelines. Rects are a signed distance field, one instance
format, one draw call for a frame. Paths come with flattening, stroke-to-fill
with caps, joins and dashes, both winding rules, antialiased clipping and all
sixteen blend modes — and *two* rasterisers for them: stencil-then-cover on
the CPU, modelling a GPU stencil buffer down to its eight-bit wraparound, and
an analytic one that computes coverage from the curves themselves and runs on
either.

Týr has three font parsers of its own, all compiled in by default and none
needing anything linked: `glyf` for TrueType, a Type 2 charstring interpreter
for CFF, and eexec plus Type 1 charstrings for PostScript fonts. FreeType and
stb_truetype remain optional and preferred when present. The encoding chain —
`/Differences`, the three standard encodings, glyph names to code points,
CID-keyed lookups — resolves codes to glyphs.

Lyngvi opens a window on Win32 and creates a Vulkan instance, device,
swapchain and pipeline through bindings written by hand and loaded at run
time, so the default build still links no C and needs no SDK. With a shader
compiler on `PATH` the GLSL becomes SPIR-V at build time.

There are two path rasterisers and the reader will use either. `--path cpu`
rasterises each page into an image and uploads it as a texture, which is
exactly the picture `fenrir raster` writes. `--path gpu` sends the *outlines*
to the device and works out coverage in the fragment shader, analytically,
from the curves — so a page is one draw call, a zoom is a matrix rather than
a re-render, and a clip is multiplied in instead of needing a stencil buffer.
`-Dpath=cpu|gpu|both` decides which the window may use; the default is both,
so the two can be compared, and `fenrir raster --path both` is that
comparison. The GPU path draws every mark on a page but cannot yet sample an
image or composite a blend mode, so `--path cpu` is still the one that draws
a document in full.

Images decode. Flate and the other byte filters give samples directly, and
`/DCTDecode` goes through a baseline JPEG decoder written for this, so the
figures and photographs on a page are on the page. JPEG 2000, CCITT and
JBIG2 are counted and skipped.

## Building

```
zig build              # zig-out/bin/fenrir
zig build test         # 626 tests
zig build run -- info file.pdf
```

### Which path rasteriser

```
zig build              # both, selectable at run time -- the default
zig build -Dpath=cpu   # the window only ever uses the CPU rasteriser
zig build -Dpath=gpu   # the window only ever uses the analytic pipeline
```

A build with both lets `fenrir read --path cpu|gpu` choose, and
`fenrir raster --path both` render a page each way and subtract. A build with
one refuses the other by name rather than silently falling back.

The flag decides what the *window* draws with, not what the binary contains:
`fenrir raster` and `fenrir read --shot` render with no device in the process
at all, so the CPU rasteriser is compiled either way.

`both` is the default in every optimisation mode, and stays so until the GPU
path can sample an image and composite a blend mode -- a release build with
only that one would show a document with its figures missing and its
highlights opaque.

Requires Zig 0.16.0. The default build links no C at all — not even Vulkan,
which is opened by name at run time rather than linked, so a machine with no
driver gets a sentence instead of a link error. On Windows the build links
`user32`, because Lyngvi's window is Win32 calls declared by hand.

### Shaders

The GLSL in `src/gleipnir/shader/` is compiled to SPIR-V by the build, using
`glslc`, `glslang` or `glslangValidator`, whichever is on `PATH` first. Neither
being present is not an error:

```
zig build              # looks for a shader compiler; carries on without one
fenrir view --probe    # says whether this binary has SPIR-V in it
```

**Getting a shader compiler.** Any one of these is enough; the build needs only
the executable on `PATH`, never the SDK's headers or libraries.

| | |
|---|---|
| Vulkan SDK | [vulkan.lunarg.com](https://vulkan.lunarg.com) — gives `glslc` *and* the validation layers, which are the best debugging tool for a Vulkan bring-up. `winget install LunarG.VulkanSDK` on Windows. |
| glslang alone | [github.com/KhronosGroup/glslang/releases](https://github.com/KhronosGroup/glslang/releases) — one ~5 MB `glslang` binary, no installer, no admin. Unzip and put `bin/` on `PATH`. |
| A package manager | `apt install glslang-tools`, `brew install glslang`, `pacman -S shaderc` |

Every shader must ask for `GL_GOOGLE_include_directive` by name if it
`#include`s anything. `glslc` enables it implicitly and `glslang` does not, so
a shader without that line compiles with one and fails with the other. Tried aganst glslang-16.5.0-x86_64-release.

A binary built without one opens its window, creates its device and swapchain,
acquires and presents images, and draws nothing, with a message saying so. That
is a deliberate half-measure rather than a failure: it keeps everything except
the draw call testable on a machine with a driver and no SDK, which is the
normal state of a machine that has never installed one.

### Font backends

```
zig build -Dfreetype               # link FreeType as a glyph backend
zig build -Dstb-truetype           # compile stb_truetype (vendor the header first)
zig build -Dharfbuzz               # link HarfBuzz as the UI text shaper
zig build -Dfont-backend=freetype  # which glyph backend to try first
```

On a system where `linkSystemLibrary` cannot find a library on its own —
which means anywhere without pkg-config, so most Windows machines — give the
paths instead. The include directory is the one holding `ft2build.h`, which in
a normal install is `<prefix>/include/freetype2` and not `<prefix>/include`:

```
zig build -Dfreetype -Dfreetype-include=<prefix>/include/freetype2 \
                     -Dfreetype-lib=<prefix>/lib
```

These flags decide what is *linked*. Which backend opens a given font stays a
runtime decision, so a build with two of them can render the same page each
way and diff the results — which is the main reason to have two. `fenrir
fonts` prints what the binary you have can actually do.

## The CLI

Vánagandr exists to make the rest of the project debuggable. It is the tool
you reach for when a page renders wrong three milestones from now.

```
fenrir info <file>                      summarise header, trailer, xref, storage
fenrir dump <file> [--all] [--obj N]    print the object graph
             [--follow] [--depth N]
fenrir pages <file> [--verbose]         every page and its effective geometry
fenrir xref <file> [--verify]           where every object lives
fenrir extract <file> <N> [--raw]       a stream's decoded bytes
fenrir extract <file> --page <N>        a page's content stream
fenrir trace <file> [--page N|--all]    a page interpreted into a display list
             [--stats] [--paths]
             [--glyphs] [--no-rotate]
fenrir raster <file> [--page N|--all]   a page rendered to a PNG, on the CPU
             [-o F] [--dpi N|--scale N]
             [--samples 1|2|4|8] [--fonts]
             [--tolerance N] [--stats]
             [--path stencil|slug|both] [--rays N]
             [--text-boxes] [--image-boxes]
             [--no-annots] [--ascii x,y,w,h]
fenrir read <file> [--page N]           the document in a window, scrollable
             [--zoom N|--dpi N] [--size WxH]
             [--path cpu|gpu] [--samples N]
             [--frames N] [--shot F] [--vsync ...]
fenrir fonts                            what Týr can do in this build
fenrir rects [--out F] [--size WxH]     a demo frame through the rect pipeline
fenrir ui    [--out F] [--atlas F]      a frame of interface, text included
             [--size WxH] [--mouse X,Y]
fenrir view  [--frames N] [--size WxH]  the same interface, in a window, on
             [--vsync on|off|adaptive]  the GPU
             [--validate] [--gpu NAME]
fenrir view --probe                     the devices, without opening anything
```

`fenrir read file.pdf` is the one that opens a document to read. It opens
fitted to the width of the window, scrolls continuously with the wheel, zooms
with `+` and `-`, refits with `0`, and steps a page at a time with `n` and
`p`. The percentage in the title bar is the page's true physical size on the
display, display scaling included — not the raster scale, which is a
different number on every screen.

Pages are prepared on a thread of their own and the frame loop never waits
for one: a page that is not ready yet is blank paper for a few frames rather
than a frozen window. That matters more than it sounds. A page whose figure
is a scatter plot of a few thousand separately clipped markers takes about a
second to rasterise, and doing that on the frame thread does not make the
reader slow, it makes it stop.

`--shot F` writes one composed frame to a PNG with no window and no device at
all, which is how the layout is checked on a machine with no display.

`fenrir raster file.pdf --page 1` writes the same picture to a file: parser,
interpreter, path pipeline and font layer end to end, on the CPU, with no
device or window involved. It reports what it could *not* draw rather than
letting a page with a hole in it look finished.

```
$ fenrir raster paper.pdf --page 8 --dpi 110
page 8  935x1210  0 fills  1 strokes  0 clips  103515 segments
         0 annotations drawn, 8 skipped
         6 images decoded
wrote page-8.png
2833 of 2833 glyphs drawn, 0 blank, 0 invisible
every mark on the page was drawn
```

`--path both` renders the page through both rasterisers and reports how far
apart they came out, in levels of 255. The mean halves every time the
stencil rasteriser's sample count doubles, which is what it looks like when
two implementations agree and one of them is the limit the other converges
to:

```
$ fenrir raster paper.pdf --page 1 --path both --samples 1 --stats
         stencil vs slug: mean 8.067, worst 224.8, 13.292% over 1 level
$ fenrir raster paper.pdf --page 1 --path both --samples 8 --stats
         stencil vs slug: mean 1.527, worst 83.9, 12.202% over 1 level
```

`--ascii x,y,w,h` prints a window of the result as text, one character per
pixel at five levels of ink. A one-pixel seam along a shared edge is invisible
in an image viewer and unmistakable in a grid of characters; it is `fenrir
trace` for the other end of the pipeline. `--fonts` lists which backend opened
each font, how many glyphs it has, and how its encoding was resolved, which is
where the answer to "why is this page blank" almost always is.

`fenrir extract file.pdf --page 1` prints a decoded content stream — the
actual graphics language a page is written in; `fenrir trace file.pdf --page 1`
prints what the interpreter made of it.
`fenrir xref --verify` checks that every offset in the table really points at
its own `N G obj` header, which is the single most useful signal about
whether a file is well-formed.

`fenrir view --probe` opens the Vulkan loader, enumerates the devices, and
prints what each one can do without creating a window, so it works over ssh
and on a machine with no display. It is the first thing to run when something
is wrong, and the last line of it is the one that matters:

```
device 0  NVIDIA GeForce GTX 1650 SUPER
  kind          discrete, NVIDIA
  api           1.4.351
  memory        3930 MiB device-local
  swapchain     yes
  indexing      yes
```

`indexing` is descriptor indexing, and it decides whether a frame is one draw
call or one per run of instances sharing a texture — 1 against 18 for the demo
interface.

## Layout

Dependencies run strictly one way. Nothing below `Document` knows that
documents exist, which is what lets the same parser read the file body, the
inside of an object stream, and a content stream. Nothing at or below
`Document` knows what a page is.

```
src/
  root.zig                  public library surface
  main.zig                  CLI entry and dispatch
  gjoll/                    Gjöll
    object.zig              the 8 object types; no allocation, no ownership
    Lexer.zig               bytes -> tokens
    Parser.zig              tokens -> objects; knows nothing of documents
    xref.zig                both table encodings, /Prev chains, reconstruction
    Document.zig            resolution, object streams, stream decoding
    pages.zig               the page tree walk and attribute inheritance
    Page.zig                a page, its geometry, and its content stream
    print.zig               objects -> readable text
    filter.zig              the filter pipeline
    filter/
      predictor.zig         PNG and TIFF predictors
      ascii.zig             ASCIIHex, ASCII85, RunLength
      lzw.zig               LZWDecode
    content.zig  content/   the content-stream interpreter
      Scanner.zig           operators and operands, inline images included
      Interpreter.zig       the operator table and the graphics state
      matrix.zig            the interpreter's f64 matrix
      color.zig             all eight colour space families, resolved to RGBA
      function.zig          PDF function types 0, 2, 3 and 4
      Font.zig              widths and code decoding out of a font dictionary
  gelgja.zig  gelgja/       Gelgja
    geom.zig                points, matrices, bounds, path verbs
    paint.zig               colour, stroke parameters, blend modes, layers
    DisplayList.zig         DrawCmd and the recorded list
    Builder.zig             the recording API the interpreter calls
    trace.zig               a display list as diffable text
  gleipnir.zig  gleipnir/   Gleipnir
    sdf.zig                 the distance field, in Zig; the shader mirrors it
    rect.zig                the 96-byte instance and its packing
    DrawList.zig            the call sites, the clip stack, the transform stack
    software.zig            a CPU rasteriser, used as an oracle not a renderer
    png.zig                 so the oracle's output can be looked at
    pipeline.zig            bindings, push constants, blend state, features
    shader/
      rect.glsl             the instance layout, shared by both stages
      rect.vert  rect.frag  the quad and the field
  tyr.zig  tyr/                   Týr
    Face.zig                glyph index -> outline, behind a runtime vtable
    Outline.zig             a glyph in Gelgja's verbs; quads elevated to cubics
    Shaper.zig              string -> positioned glyphs; UI only, never a page
    format.zig              sniffing TrueType, CFF, Type 1 from the bytes
    registry.zig            the one place that knows which backends are built
    raster.zig              outline -> coverage, by signed-area accumulation
    Atlas.zig               glyphs packed by (face, glyph, size, subpixel x)
    Fonts.zig               faces, the atlas, the shaper, and text layout
    backend/
      fallback.zig          always present; draws every glyph as a notdef box
      freetype.zig          -Dfreetype
      stb.zig               -Dstb-truetype
      harfbuzz.zig          -Dharfbuzz; a Shaper, not a Face
  thviti.zig  thviti/       Þviti
    key.zig                 a box's identity: a hash of a string and a parent
    Box.zig                 the node: asked for, solved, and remembered
    input.zig               what Lyngvi produces, one frame at a time
    UI.zig                  the tree, the stacks, the five passes, the signals
    text.zig                the one file that knows both Þviti and Týr
    draw.zig                the tree, turned into Gleipnir instances
    widgets.zig             enough controls to prove the core is usable
  lyngvi.zig  lyngvi/       Lyngvi
    vk.zig                  Vulkan, declared by hand; no headers, no SDK
    loader.zig              the loader opened by name, and three dispatch tables
    spirv.zig               enough of the format to check a module before use
    shaders.zig             the compiled blobs, or the reason there are none
    choose.zig              every decision, as a function of its inputs
    Window.zig              fifteen functions; one implementation per platform
    Events.zig              a message loop's output, as one frame of input
    win32.zig               thirty externs and a window procedure
    x11.zig                 stubbed, so the interface has two implementors
    Device.zig              instance, surface, physical device, queues
    Swapchain.zig           images, views, framebuffers, and the render pass
    Renderer.zig            the rect pipeline, and one vkCmdDraw per frame
  vanagandr/                Vánagandr
    Context.zig             allocator, Io, and the two writers
    info.zig  dump.zig  pages.zig  xref.zig  extract.zig  fonts.zig
    rects.zig               draws a demo frame with no GPU in the process
    ui.zig                  the whole stack, end to end, into a PNG
    view.zig                the same stack, end to end, into a window
```

Þviti is the only layer that imports across, and it does so in two named
files: `text.zig` reaches Týr and `draw.zig` reaches Gleipnir. `UI.zig` itself
imports neither — it asks how wide a string is through a vtable and produces
nothing but a tree — so the layout solver, which is the part with all the
arithmetic in it, is tested with no fonts, no atlas and no renderer anywhere
in the test.

Gelgja imports neither the PDF layer nor any graphics API, which is what lets
its tests run with no document and no GPU. Týr imports Gelgja's geometry and
nothing else — in particular it never sees a character code, only glyph
indices and glyph names, so two backends can be diffed without their
disagreements being confused with an encoding bug.

### Memory

A `Document` owns the file bytes and one arena. Every `Object` handed out
borrows from one or the other, so objects are cheap to copy and nothing
returned from the library needs freeing. `deinit` releases the arena
wholesale.

Names and strings that need no unescaping are slices of the file buffer; only
the ones with `#xx` or `\` escapes are copied into the arena.

## What works

- Both cross-reference encodings: the classic `xref` table and the PDF 1.5
  compressed cross-reference stream.
- `/Prev` chains, hybrid-reference files (`/XRefStm`), and cycle detection.
- Object streams (`/Type /ObjStm`).
- FlateDecode, LZWDecode, ASCIIHexDecode, ASCII85Decode, RunLengthDecode, and
  the PNG and TIFF predictors. Image codecs (DCT, JPX, CCITT, JBIG2) are
  recognised and passed through encoded rather than decoded — they produce
  pixels, which belongs to Gleipnir.
- The page tree, with the four inheritable attributes (`/Resources`,
  `/MediaBox`, `/CropBox`, `/Rotate`) resolved to their effective values, the
  crop box clipped to the medium, and rotation applied to the displayed size.
- Page content: `/Contents` as either a single stream or an array of them,
  joined *with whitespace between the parts*. The split points are arbitrary,
  so a token can straddle two streams; joining without the separator corrupts
  one operator at every seam, silently.
- Gelgja: the `DrawCmd` vocabulary, the recording builder, and the trace
  backend, now driven by the interpreter that was written against them.
- The content-stream interpreter: all 73 operators of table A.1, the graphics
  and text state with `q`/`Q`, deferred clipping, form XObjects with their
  matrices, bounding boxes and transparency groups, inline images decoded into
  the display list so it stays replayable without a document, all eight colour
  space families, PDF function types 0, 2, 3 and 4 — including the PostScript
  calculator, because spot colours are specified with one — shading and tiling
  patterns in pattern space, embedded CMaps, and Type 3 glyph procedures run
  as the content streams they are, and annotation appearance streams fitted to
  their rectangles by §12.5.5 — which is where a highlight, a stamp, a filled-in
  form field and a signature live, and none of which are in the content
  stream. `fenrir trace` prints the result; 236 million operators across the
  corpus produce no unimplemented operator.
- Gleipnir's rect pipeline: the instance format, the draw layer with its clip
  and transform stacks, the distance field, and a CPU rasteriser that runs the
  same arithmetic a fragment shader would. `fenrir rects` writes a frame to a
  PNG, and `fenrir view` hands the same instances to a real device.
- Gleipnir’s path pipeline, on the CPU: flattening by Wang’s formula,
  stencil-then-cover fills under both winding rules, stroke-to-fill with caps,
  joins, miters and dashes, antialiased path clipping, transparency groups,
  and all sixteen PDF blend modes — composited in the device’s own colour
  space, which is what §11.3.8 asks for and what keeps a page from reading
  like a photocopy of one.
- Gleipnir's **analytic** path rasteriser, in `slug.zig`, on both the CPU and
  the GPU. Coverage comes out of the outline in closed form rather than out of
  samples: a horizontal ray across a pixel gives the exact covered length of
  that row, and only the integral down the pixel's height is sampled. A
  vertical edge — most of what a page of text is made of — lands on its true
  coverage from a single ray, where eight multisamples would give it nine
  possible values. The curves go to the device as curves, so a zoom is a
  matrix rather than a re-tessellation, and a clip is another outline whose
  coverage is multiplied in. `fenrir raster --path both` renders a page each
  way and reports the difference; on a page of text the two converge as the
  stencil rasteriser's sample count rises, which is the evidence that they
  agree and that the analytic one is the limit.
- Image decoding: the packing (1, 2, 4, 8 and 16 bits a component, rows byte
  aligned), every colour space `color.zig` knows including `/Indexed`
  palettes and `/Separation` tint transforms, `/Decode` arrays, `/ImageMask`
  stencils painted with the current fill, `/SMask` alpha at any resolution,
  and a baseline JPEG decoder — Huffman, dequantisation, a separable inverse
  DCT, chroma upsampling, restart markers and the Adobe transform flag.
  Images are sampled onto the page through the inverse of their placement
  matrix, so a rotated or sheared one is right, and averaged when minified so
  a page-sized photograph does not shimmer.
- Týr: the `Face` and `Shaper` interfaces, format sniffing, the outline sink,
  and the backend registry with its selection rules. Three native backends are
  compiled in by default — `glyf` for TrueType, a Type 2 charstring
  interpreter for CFF, and eexec plus Type 1 charstrings for PostScript fonts
  — with FreeType, stb_truetype and HarfBuzz written against the same
  interfaces and preferred when they are built in.
- Týr's glyph pipeline: a signed-area scan converter, a skyline-packed atlas
  keyed by `(face, glyph, size, subpixel x)`, and text layout with a shaped-run
  cache. A backend that rasterises is asked to; one that only decomposes has
  its outlines filled by Týr's own, which is why all of this runs on a machine
  with no C dependencies at all.
- Þviti: box identity, the tree, semantic sizing and its five-pass solver, the
  parent and style stacks, mouse and keyboard signals, focus and tab order,
  scrolling, and frame-rate-independent animation. `fenrir ui` builds a
  reader's chrome, solves it, rasterises its text, turns it into rect
  instances and writes the result as a PNG — every layer but the Vulkan
  backend, on one path.
- Lyngvi: a Win32 window with DPI awareness, mouse capture, wheel and
  surrogate-paired text input; hand-written Vulkan bindings loaded at run
  time; instance, surface, device and queue selection; a swapchain that
  rebuilds on resize with a semaphore per image; and the rect pipeline with a
  persistently mapped instance buffer and glyph uploads that ride along with
  the frame. `fenrir view` runs it on the demo interface and `fenrir read`
  runs it on a document: on the machine this was written on it opens a window
  on a GTX 1650 SUPER, picks `b8g8r8a8_srgb` and three images, uploads a
  rasterised page as a texture, and presents it at the refresh rate.

### Damage tolerance

Real files are broken constantly, so recovery is a feature rather than an
afterthought. Each of these is exercised by a test or by the corpus:

- A wrong or indirect `/Length` falls back to scanning for `endstream`.
- A `/Prev` offset that misses its section by a few hundred bytes — which
  happens whenever a file is repaired or re-saved — is found by searching
  nearby instead of abandoning the rest of the chain.
- An object whose offset is stale is found by rescanning for its header.
- A table that parses but does not lead to a resolvable page tree is rejected
  and rebuilt by scanning the whole file for `N G obj`.
- A document with no usable trailer recovers `/Root` by finding the object
  whose `/Type` is `/Catalog`.
- A page tree that is missing, unreachable, or cyclic falls back to scanning
  for `/Type /Page` objects, recovering each one's inherited attributes by
  climbing `/Parent` instead of descending.
- Page-tree nodes without `/Type` are classified by shape: something with
  `/Kids` is interior, anything else is a leaf.
- A reversed or degenerate `/MediaBox` is normalised or replaced with the
  default rather than producing a page of zero area.

Verified against 40 real documents (PDF 1.2 through 1.7, 14 to 19,218
objects, 2 to 658 pages, 6,511 pages in total): all open, none needed
reconstruction, 11 use object streams. Every one of those documents' `/Count`
agrees exactly with the number of leaves the walk finds — an independent
check, since `/Count` is the producer's number and ours comes from
enumerating the tree.

Truncated, byte-prepended, zero-holed, and random-garbage inputs produce no
crashes. A file with 19 junk bytes prepended — which invalidates every offset
in it — still reads completely.

## Not implemented

- **Encryption.** Detected and reported; `/Encrypt` documents parse
  structurally but their strings and stream data read as ciphertext. Most
  encrypted files in practice have an empty user password, so this is the
  next thing worth adding.
- **Two approximations in the interpreter**, each confined to one function and
  named where it lives. A `/Type0` font whose `/Encoding` is a predefined CMap
  other than Identity decodes two bytes at a time — right for all of them —
  with the wrong CID mapping for the CJK ones; *embedded* CMap streams are
  parsed properly. And a clipping text render mode (`Tr 4`–`Tr 7`) clips to a
  box per glyph rather than to the outline, which shows a little too much
  rather than nothing.
- **A font the document does not embed is substituted, not matched.** A PDF
  may name `/Helvetica` and ship no program; a face off this machine stands in
  for it. The shapes are borrowed and only the shapes — positions still come
  from the PDF's own `/Widths` — so the page is legible and not
  typographically faithful.
- **Three image codecs.** Flate, LZW and the ASCII filters give samples
  directly, and `/DCTDecode` goes through a baseline JPEG decoder written for
  this — with the packing, the colour space, `/Decode` and `/SMask` all
  applied. **`/JPXDecode`, `/CCITTFaxDecode` and `/JBIG2Decode` are not
  decoded**, so a fax-coded or JBIG2 scan still renders as its invisible OCR
  layer over nothing. Progressive JPEG is refused rather than decoded as
  baseline. Each is counted and named in the report. Inline images
  (`BI ... ID ... EI`) carry their samples in the display list and are not
  reached yet either.
- **Shadings and tiling patterns.** The interpreter resolves both into a
  `Paint`; painting them needs a gradient rasteriser and a recursive replay.
  Solid paint is exact and everything else is counted and skipped.
- **Transparency groups are approximated.** `layer_push` multiplies its alpha
  into everything inside and applies the group’s blend mode to each thing it
  contains, which is exact for a non-isolated, non-knockout group whose
  contents do not overlap — a highlight, a stamp, most of what a group is used
  for — and wrong when they do. Doing it properly needs an offscreen canvas
  per group.
- **The GPU path pipeline does not composite blend modes, and cannot sample
  an image.** It draws every fill, stroke and glyph on a page in one call and
  clips them analytically, but a `/Multiply` highlight comes out as plain
  source-over, and an image has to be drawn by the rect pipeline as a
  textured quad — which `--path gpu` does not yet arrange, so under it a page
  draws its marks and not its figures. Both are counted. `--path cpu` has all
  of it and is the default in a build with both.
- **Stencil-and-cover was specified and then not used.** `gleipnir/pathpipe.zig`
  is a complete contract for the classical GPU path fill and `raster.zig` is a
  faithful CPU model of it, down to the eight-bit stencil wraparound. The
  analytic pipeline won on three counts — one pass instead of two, no
  multisampled attachment, and an antialiased clip that a stencil bit cannot
  express — so `pathpipe.zig` stays as the argument and as the other half of
  a comparison rather than as something that runs.
- **Annotations are drawn from their appearance streams only.** A `/Highlight`
  or `/Square` that ships no `/AP` is skipped rather than synthesised from its
  `/QuadPoints` and `/C`, and no annotation is interactive: a link is drawn if
  it has an appearance and is never clickable.
- **The standard-14 metrics.** A simple font with no `/Widths` still advances
  half an em per glyph; the AFM files are not in the tree.
- A real widget set on top of Þviti — text fields with selection and an IME,
  menus, tab bars, trees, splitters.
- Lyngvi's xcb backend, and everything platform-shaped a reader eventually
  needs: file dialogs, menus, the clipboard.

## Where this is going

### 4. Gelgja — the display list *(interface landed)*

The content-stream interpreter emits a display list, not immediate calls into
a live backend. A `[]DrawCmd` built once per page and replayed is cacheable,
diffable, testable without a GPU, and reorderable; immediate `fillPath()`
calls are none of those, and it is a painful thing to change later. So the
interface came first, before the interpreter that fills it.

Three decisions in it are load-bearing:

- **Curves are not flattened.** Subdividing a Bézier needs a tolerance in
  device pixels, which depends on the zoom. A flattened list must be rebuilt
  every time the user touches the scroll wheel; one that keeps its cubics is
  built once per page and replayed at any scale.
- **The CTM is baked into path points, but `stroke_path` still carries it.**
  Fills only need geometry. Strokes do not: the pen is a circle in *user*
  space, so a non-uniform matrix makes it an ellipse, and a zero width means
  "as thin as the device can draw". Neither survives baking.
- **Everything lives in flat shared arrays addressed by `Range`.** A page with
  ten thousand small paths costs one allocation per array rather than ten
  thousand, and the list stays contiguous and serialisable.

The trace backend is written. It prints a list as text, which settles the
question that gets expensive later: when a page looks wrong, is the
interpreter wrong or is the rasteriser wrong?

```
# page [0.00 0.00 612.00 792.00]
# 11 cmds: 2 fill, 1 stroke, 1 clip, 1 text (6 glyphs), 1 image, 0 shading, 1 layer
clip_push nonzero 5v/4p [36.00 36.00 576.00 756.00]
  marked_begin /Span
    fill nonzero rgb(0.850 0.200 0.200) 5v/4p [72.00 720.00 540.00 722.00]
  marked_end
  text /F1 "ABCDEF+Helvetica-Bold" 17.20pt mode=fill rgb(0.100 0.100 0.100) 6g "Gelgja"
  stroke w=0.75 cap=butt join=round limit=10.0 dash[4.00 3.00]@0.00 rgb(0.400 ...)
  layer_push alpha=0.500 blend=multiply
    fill nonzero rgb(0.200 0.450 0.900) 2v/4p [300.00 600.00 460.00 680.00]
  layer_pop
  image /Im1 1200x800 obj=31 [468.00 0.00 0.00 312.00 72.00 200.00]
clip_pop
```

Still to come: **a page rasteriser**, pixel-diffed against `mutool draw` or
`pdftoppm`. That is the ground truth, and it becomes the regression suite. The
PNG writer it needs already exists, in Gleipnir, for the rect pipeline's own
CPU reference.

There is deliberately no SVG backend. The browser was never the goal; the goal
was a renderer trustworthy enough to bisect against, and SVG stops being
trustworthy exactly where PDF gets hard — blend modes, soft masks, shading
types 4–7, text rendering modes, dash phase.

### 5. Lyngvi — window and device *(landed)*

The estimate was fifteen functions: open a window, drain events, block until
input, hand back a Vulkan surface. The vtable has ten, and a test asserts it
stays under fifteen — because everything else a window appears to do (hit
testing, focus, hover, cursors over a control, drag and drop inside the
program) belongs to Þviti and was already written, and a platform layer that
grows is a portable program acquiring three subtly different behaviours.

Win32 first, xcb stubbed from day one. The stub is not a placeholder for
politeness: an interface with one implementor is not an interface, and writing
the second one's *signature* is what proved this one is not quietly
Win32-shaped. Three things in the design come from it — `Window.Native` has an
`xcb` arm, wheel movement is reported in pixels rather than notches because
X11 delivers it as button presses with no magnitude at all, and
`scroll_line_pixels` exists because in that arrangement nobody else has the
number.

**Vulkan is declared by hand and opened by name.** No `vulkan.h`, no
`@cImport`, no `vulkan-1.lib`, no SDK: the ABI is frozen, the loader is
reached through one symbol, and `std.DynLib` (plus three `kernel32`
declarations on Windows, where that does not compile) finds it at run time.
The cost is a day of transcription. The benefit is that a machine with no
driver gets a sentence — and that the default build of a PDF reader still
links no C at all.

One rule keeps the transcription safe, and it is worth stating because it is
what makes the shortcut legitimate: structures **passed to** the driver must be
byte-exact, because it reads fields at fixed offsets, and structures **filled
in by** it may be larger than the real thing, because it writes only what its
own header says. So every `CreateInfo` is written out in full, and
`VkPhysicalDeviceLimits` — a hundred members, of which four are read — is four
named fields and a generously oversized tail. Getting that wrong in the safe
direction wastes half a kilobyte of stack; getting a `CreateInfo` wrong is a
black window.

**Three dispatch tables, not one.** Device-level functions can be fetched from
the instance, where the loader inserts a trampoline that reads the dispatch
table out of the handle on every call, or from the device, where the pointer
goes straight into the driver. For `vkCmdDraw` that is the difference between
a call and a dependent load followed by a call, so the device table is filled
with `vkGetDeviceProcAddr` and the tables are filled by `inline for` over
their own fields rather than by a hundred hand-written assignments — which is
the same code with one chance per line to paste the wrong name into the wrong
field, a mistake that compiles and then calls a real Vulkan function with the
wrong arguments.

**The decisions are not in the Vulkan files.** Initialisation is mostly not API
calls; it is a dozen small judgements surrounded by the calls that fetch the
candidates. Which surface format, which present mode, how many images, which
memory type, which queue family, which of two GPUs — all of it is in
`choose.zig` as pure functions over the arrays Vulkan returns, and all of it is
tested against the cases that never come up on the machine the code was
written on: a driver offering no sRGB format, a compositor reporting
`0xFFFFFFFF` for its extent, a surface with no maximum image count, a device
whose only host-visible memory is also device-local, a queue family that can
present but not draw.

Three details in that file are load-bearing and each is a bug someone else
would have found:

- `max_image_count` of zero means *no maximum*, and clamping to it
  unconditionally asks the presentation engine for zero images.
- One more image than the minimum, because asking for exactly the minimum
  makes every acquire block until the compositor releases the previous frame —
  which turns a 2ms frame into a 16ms one and looks exactly like a slow
  renderer.
- The render-finished semaphore belongs to the swapchain *image*, not to the
  frame in flight. With one per frame, two frames can present different images
  while signalling the same semaphore, and the presentation engine may wait on
  a signal already consumed. It works on the machine it was written on. The
  official tutorial had this wrong for years.

The instance buffer is mapped once and never unmapped — mapping per frame is a
driver call and a page-table update to obtain a pointer that was already valid
— and it asks for host-visible memory while *preferring* device-local, so on a
machine with resizable BAR it lands in video memory without being asked to and
on one without it lands in system memory and everything still works. Glyph
uploads ride along in the frame's own command buffer ahead of the render pass,
so a frame that adds characters to the atlas does not stall the queue.

Text is the part of an input API that is easy to get wrong quietly. The mouse
is state, so a platform that coalesces twenty motion events cannot
desynchronise anything; the keyboard is an ordered list, because typing `a`,
backspace, `a` leaves the same state as typing nothing and a text field has to
see all three; the wheel accumulates and resets, because reporting each tick as
an event makes a UI scroll in steps at whatever rate the mouse driver chose.
`WM_CHAR` arrives as UTF-16, so anything outside the basic plane is two
messages that are nothing at all until they are paired. And the text bytes are
double-buffered, because Windows runs its own modal message loop while a window
is being dragged and calls the window procedure from inside it — so input can
arrive in the middle of a frame, and the buffer the frame is reading must not
be the one being appended to. That one was found by a test, in the least
ambiguous way available: every byte came back `0xaa`.

```
fenrir view --frames 120
NVIDIA GeForce GTX 1650 SUPER (NVIDIA), Vulkan 1.4, fifo
1100x760 in 3 swapchain images, b8g8r8a8_srgb
120 frames drawn, 0 skipped, 0 swapchain rebuilds
742 instances at the high-water mark
atlas 1024x256, 8 glyphs, 872 bytes uploaded
```

What is still missing is the SPIR-V. The GLSL is compiled by the build when a
shader compiler is on `PATH` and this machine has none, so that run acquired,
cleared and presented 120 images and drew nothing. That is a real state and it
is handled rather than papered over: `spirv.zig` parses whatever the build
produced and checks it is SPIR-V at all, is not byte-swapped, and declares the
stage and the capabilities the pipeline is about to ask the device for — the
class of failure whose symptom is a pipeline that creates successfully, draws
nothing, and reports nothing.

Not here, and each of them a separate self-contained addition: file dialogs,
menus, the clipboard, drag and drop from other applications, and any fallback
to OpenGL or Direct3D. A machine without Vulkan gets a message saying so
rather than a silently slower program.

### 6. Gleipnir — pixels *(rect and path pipelines landed)*

**The rect pipeline is written.** One instance format
draws every rectangle the reader will ever put on the screen — panels,
buttons, scrollbars, shadows, image tiles, and, with the source rect pointing
into a glyph atlas, every character — as a rounded box evaluated from a signed
distance field, with per-corner radii, four corner colours, border thickness
and edge softness. Ninety-six bytes each, no per-shape state, and therefore
**one draw call for a whole frame**.

Two decisions carry that claim.

**The clip lives in the instance, not in the command buffer.** The obvious
place for a scissor is `vkCmdSetScissor`, and it costs a draw call every time
the clip changes — which in a UI is constantly: every scroll view, every list
row that elides, every text field. A frame with two hundred clipped regions is
two hundred draw calls. Sixteen bytes per instance buys all of them back. The
vertex shader shrinks the quad to the intersection of the rect and its clip,
so clipping is enforced by rasterisation instead of by state and instances
with different clips sit next to each other in one buffer. It is also strictly
*less* GPU work than a scissor test, because the clipped-away fragments are
never generated.

**The fragment shader reads the instance rather than a dozen varyings.** The
vertex stage emits a position and one flat integer, and the fragment stage
fetches the same struct out of the same storage buffer. That is not only
smaller: a bilinear corner gradient cannot be passed as interpolated varyings
at all, because a bilinear function over a quad is not two linear functions
over its triangles, and the diagonal shows.

The transform stack is scale and offset, not the full affine the interpreter
works in. A rotated rectangle is not a rectangle, so it cannot be one
instance, and the alternatives are six more floats and a matrix multiply per
vertex, or silently drawing the wrong shape. `Xform.fromTransform` returns
null for a matrix this layer cannot honour, so the interpreter finds out by
being told rather than by looking at the output. The one rotation a reader
really needs, `/Rotate 90` on a page, is a property of the whole frame and
belongs in the projection.

Anything genuinely rotated or skewed is a path, and paths are the second
pipeline: stencil-then-cover, which handles nonzero and even-odd winding
without triangulating anything. That one is not started. The split is not
about rendering quality, it is about batching — a rect needs no per-shape
state, so ten thousand of them are one draw call, while a path needs a stencil
pass and so is at least two. Anything expressible as a rect must be one, or
the frame rate is set by the chrome rather than by the document.

Colours are sRGB-encoded bytes, decoded to linear in the shader and blended in
linear light against an `_SRGB` swapchain. Eight bits is exactly the budget
that encoding exists to fit; eight bits of *linear* light bands visibly in the
darks. The known cost is that antialiased text blended in linear light looks
thin when it is light on dark, and the fix for that is stem darkening in the
glyph atlas, not blending in the wrong space.

**The instances now reach a real device** — Lyngvi's `Renderer` is the other
half of `pipeline.zig`, and it is the only file in the project that both knows
what a `DrawList` is and calls `vkCmdDraw`. **The shader still has not run**,
because compiling it needs a shader compiler this machine does not have.

What was checked without one: the distance field is implemented in Zig and
tested against known distances, then transliterated into GLSL line for line; a
CPU rasteriser drives that same arithmetic over a framebuffer the way a
fragment shader would, one pixel centre at a time, in submission order, with
the same blend equation; and `pipeline.zig` writes down the bindings, push
constants, blend factors and device features the shader assumes, each of which
produces a black window and no error message when it is wrong. A test in
`Renderer.zig` compares the two halves of that contract, which is possible
only there, because it is the only place both exist.

So the first bring-up is a diff rather than an investigation: `fenrir ui` and
`fenrir view` build the same scene from the same box tree, so the difference
between the two images is the difference between the two rasterisers.

```
fenrir rects --out frame.png
67 instances, 129 culled, 1 draw call without descriptor indexing
```

That frame is built through the real call sites, stacks and all. The 129
culled are list rows scrolled outside the panel's clip, dropped before they
reach the buffer; the one draw call is what the fallback for a device without
descriptor indexing *would* cost, which makes it a standing measure of how
well the drawing was ordered.

### 7. Týr — fonts *(three native parsers landed)*

**Two interfaces, not one.** "Font backend" is usually said as though
FreeType, stb_truetype(https://codeberg.org/andrewrk/TrueType) and HarfBuzz were three answers to one question. They
are answers to two.

| | in | out | implementations |
| --- | --- | --- | --- |
| `Face` | glyph index | outline, advance | `truetype`, `cff`, `type1` (native, always present), FreeType, stb_truetype, `fallback` |
| `Shaper` | Unicode string | positioned glyphs | HarfBuzz, `simple` |

FreeType cannot decide that `fi` should become one glyph. HarfBuzz cannot draw
a glyph. Putting them behind one interface would mean every implementation
stubbing out half of it.

The sharper consequence: **a PDF page never needs shaping.** A content stream
does not contain text, it contains glyph selectors and explicit positions. The
producer ran a shaper years ago on another machine and baked the answer into
`Tj` and `TJ`. Shaping it again would substitute our opinion of how the font
should behave for the one the document was laid out with. So HarfBuzz is
reached only for text Fenrir composes itself — menus, the search box, page
labels — and never for page content. Extraction runs the other way, through
`/ToUnicode`.

**The choice of backend is build-time; the dispatch is runtime.** Which
backends are in the binary has to be a compile-time fact, because you cannot
dispatch to a library you did not link. Which one opens a given font does not,
and should not be: the whole verification plan for Gleipnir is diffing two
renderings of the same page, and the most valuable diff is the same page
through two *font* backends. That needs both callable in one process, from one
call site, selected by a string.

So `Face` and `Shaper` are `std.mem.Allocator`-shaped — an opaque pointer and
a table of function pointers — and there is exactly one `comptime` conditional
in the whole layer, in `registry.zig`:

```zig
pub const compiled: []const *const Backend = blk: {
    var list: []const *const Backend = &.{};
    if (options.tyr_freetype) list = list ++ .{&@import("backend/freetype.zig").backend};
    if (options.tyr_stb_truetype) list = list ++ .{&@import("backend/stb.zig").backend};
    list = list ++ .{&fallback.backend};
    break :blk list;
};
```

No call site above this branches on which backend was built. Adding a fourth
is a new file and two lines here. The indirect call is paid once per glyph
decode, which is dwarfed by the charstring interpreter behind it.

The rejected alternatives are worth recording. *Comptime dispatch* — a `Face`
that is a concrete type chosen by build flag — costs nothing at runtime and
makes the cross-backend diff impossible, so it is not cheaper, it is broken.
*`std.DynLib` at startup* — no build flags, one binary, FreeType used if the
system has it — is genuinely attractive and stays possible later, since it
only changes the body of one backend's `open`; it is not the default because
it means hand-writing the symbol table with no compiler checking the C ABI,
and because it cannot work for stb_truetype, which is a header rather than a
library.

**Capabilities are not decoration.** Backends differ in ways that decide
correctness, so each declares what it can do and the registry selects on it:

```
freetype   truetype cff type1 names cmap hinting
stb        truetype cff cmap
fallback   truetype cff type1
```

The gap that matters is `names`. stb_truetype has no
`FindGlyphIndexByName`, because it parses neither the `post` table nor the CFF
charset — and every Type 1 and CFF font selected through an `/Encoding`
`/Differences` array names its glyphs. The other is `cff`: most subsetted PDF
fonts are bare CFF, so a TrueType-only backend must never be handed one. The
format is sniffed from the bytes rather than trusted from the descriptor,
because files that declare `/FontFile2` and contain CFF are not rare.

Selection order is: the preferred backend if it can take this format, then the
rest in registration order, then the fallback. A backend that accepts the
format but fails on the bytes does not end the search. The result is that
opening a font cannot fail for any reason except running out of memory.

**Outlines are the shared primitive, and rasterising is optional.** Every
backend decomposes glyphs into the same `Outline` — Gelgja's verbs, in font
units, quadratics elevated to cubics exactly. Two conversions live there
rather than in each backend, because a bug in one copy would be invisible next
to a correct one. Gleipnir's path pipeline will fill page outlines with its
own scanline code, so that a glyph drawn large and a vector edge beside it get
identical coverage.

Týr has the small-text half of that already, and it takes whichever door a
backend offers: one that rasterises is asked to, because FreeType's hinting
beats an unhinted fill by a visible margin at eleven pixels, and one that only
decomposes has its outlines filled by Týr's own scan converter.

**The atlas is keyed by the subpixel position, and that is the whole
difference between text and letters.** A run advances by fractional amounts —
an `r` is 5.34 pixels wide at eleven point — so the pen lands between pixels
almost always. Rounding each glyph to a whole pixel makes the gaps between
letters wobble by up to a pixel, which is wider than a stem, and the word
stops looking like a word; rounding only the run's start means sampling a
bitmap at a half-texel offset, which is a blur. The third option is to
rasterise the glyph *at* the fraction it lands on, from three buckets per
pixel, which is what FreeType and Skia both settle on. Baselines are snapped
and there is no vertical bucket: a horizontal stem across two rows is the one
artefact that reads as blur rather than as position.

The atlas packs by skyline into a texture of fixed width and growing height.
Fixed width because widening would re-stride every row and invalidate every
cached rectangle; growing height appends rows and leaves every `(x, y)`
exactly where it was. At the height cap it clears and starts again, at a frame
boundary and never in the middle of one. There is no LRU, deliberately:
eviction means touching a timestamp on every glyph of every frame to keep
score of a resource that is not scarce, and what it buys is one frame of
re-rasterisation in a session that filled four megabytes.

**Týr rasterises outlines itself**, by signed-area accumulation — the method
`font-rs` popularised: each segment's contribution is added to a float buffer
and a running sum along the row turns it into coverage. No sorted edge list,
no active edge table, no supersampling, and the antialiasing is analytic. It
exists because a backend is not obliged to rasterise (Týr's own `glyf` and
Type 2 parsers will produce outlines and nothing else), because it makes the
whole glyph path testable on a machine with no C dependencies, and because it
is the second opinion FreeType gets diffed against.

Its flatness tolerance is a fiftieth of a pixel rather than the tenth that
looks like enough, and a test is what moved it. Chords always cut *inside* a
convex arc, so the error does not cancel: a tenth of a pixel costs a round
glyph a quarter of a percent of its ink and shaves the outside of every bowl.
The test measures a circle's coverage against πr².

**What Týr's core keeps for itself: character codes.** `/Encoding`,
`/Differences`, CMaps, `/CIDToGIDMap` — that machinery is the same whichever
backend renders the result, so backends are handed indices and names only.
`/Widths` and `/W` come from the PDF, not the font, and win when the two
disagree, which in subsetted fonts they routinely do; `Face.advance` is the
fallback for non-embedded standard-14 faces, never the first source of truth.

Still to write: the encoding tables, the standard-14 metrics, Type 3 glyphs
(whose outlines are content streams and so run through Gelgja, not Týr), and
eventually Týr's own `glyf` and Type 2 charstring parsers — diffed glyph by
glyph against FreeType, which is what the multi-backend design is for.

### 8. Þviti — the UI *(core landed)*

**Immediate-mode call sites over a retained box cache**, following the RAD
Debugger's `ui` layer. Not either pure form.

"Immediate versus retained" conflates two independent things: the shape of the
call site, and whether per-widget state survives between frames. Dear ImGui
picks immediate for both and pays in awkward animation, awkward focus order,
and layout that lags a frame. Qt and GTK pick retained for both and pay in
ownership, invalidation, and diffing. The hybrid takes immediate call sites
and retained *state*: boxes live in a hash table across frames and carry hover
and press animation, keyboard focus, and scroll offsets. You write
immediate-mode code and get persistent state for nothing.

The key is a 64-bit hash of the call site's string seeded with the parent's
key, so `"Open"` means "the Open button *in this panel*" and two panels
showing the same buttons do not share one animation. `"Save##toolbar"`
displays `Save` and keys on the whole string; `"42 items###count"` displays
`42 items` and keys on `count` alone, so a label that counts something does
not become a different box each time the number moves. Boxes with no key at
all come from the frame arena and vanish with it, which is most of a tree —
rows, spacers, containers have nothing worth remembering.

**Sizing is semantic.** A box does not have a width, it has an opinion about
its width — so many pixels, as wide as its text, a share of its parent, or as
wide as its children need — and a *strictness* saying how much of that
opinion it will give up when the opinions do not fit. Solving is five walks
over the finished tree, run once per axis: standalone sizes, then
upward-dependent, then downward-dependent, then violations, then
relative-to-absolute. Because layout is a separate pass over a tree that
already exists, there is no one-frame lag in the geometry.

The strictness is not a priority number bolted on. A shortfall is distributed
in proportion to what each child is *willing* to lose, which is the only rule
whose answer does not depend on the order the children happened to be built
in — and build order is exactly what an immediate-mode call site makes
invisible.

Pass four has the one compromise in it: shrinking a box invalidates any
percentage its descendants computed from it in pass two, and the honest fix is
to re-run two and three for that subtree, which is quadratic. RAD does not,
and neither does this; the escape is an overflow flag that excuses a box from
being squeezed at all, which is what a scroll view uses anyway.

**What does cost a frame is hit testing**, because a box's rectangle is not
known while the tree is still being built. Hover is therefore resolved *after*
layout, against this frame's geometry, for the next frame's signals — which
makes a control interactive on the frame after it appears rather than two
frames after, and makes "the box drawn on top" and "the box that gets the
mouse" the same box without either of them sorting anything.

**A style stack, not a dozen of them.** RAD keeps one stack per field because
C macros make that ergonomic; Zig does not, so `pushStyle(.{ .fg = dim })`
merges one field onto the top and leaves the rest alone. One-shot overrides
are a separate mechanism that clears after the next box, because the classic
immediate-mode bug is a colour set for one button that quietly applies to the
next forty.

**Vulkan does not push toward a retained widget tree**, and mildly pushes the
other way. The per-frame vertex data is a few hundred kilobytes, which is
nowhere near a bottleneck. What Vulkan punishes is pipeline and descriptor
churn, and the single-primitive design already reduces that to one pipeline
and one draw call whatever the API style. Meanwhile frames-in-flight requires
2–3 copies of anything the GPU might still be reading, which suits
bump-allocating a fresh buffer each frame and penalises mutating retained
buffers in place — the latter has to track what is still in use.

The one genuine argument for a classic retained tree is accessibility: screen
reader APIs want a stable object tree to query out of band. The persistent box
cache is one, so that stays available.

```
$ fenrir ui --out ui.png
163 boxes solved, 158 drawn, 2142 glyph quads
690 instances, 1599 culled, 18 draw calls without descriptor indexing
atlas 1024x256, 8 glyphs, 0% full, 8 rasterised
```

The eighteen is the honest number and worth keeping in view: with descriptor
indexing the frame is one call, and eighteen is what the fallback path would
cost because text and panels are interleaved. Drawing all the text in a pass
would make it two. The sixteen hundred culled are outline rows scrolled
outside the sidebar's clip, dropped before they reach the buffer.

Still missing, and deliberately: a real widget set. Text fields with selection
and an IME, menus, tab bars, trees, splitters, drag-and-drop. That is a layer
written *on* this one, and writing it before there was a window to put it in
would have meant designing against an interface nobody had used. There is a
window now, which is the argument for writing it next rather than the argument
that it was wrong to wait.

## Reference

ISO 32000-2 (PDF 2.0) is the specification; the PDF Association publishes it
at no cost via [pdfa.org](https://pdfa.org/sponsored-standards/). Section
references in the source point at it.

`qpdf --qdf --object-streams=disable in.pdf out.pdf` rewrites any file into a
decompressed, readable form — the fastest way to check this parser's output
against a known-good one.

The binding of Fenrir is told in Gylfaginning 34, in Snorri Sturluson's Prose
Edda. Gleipnir's six ingredients were the sound of a cat's footfall, the
beard of a woman, the roots of a mountain, the sinews of a bear, the breath
of a fish, and the spittle of a bird. They no longer exist, having been used
up in the making.

# final goal: remove glslc dependency https://github.com/khronosGroup/glslang#ast---spir-v-back-end
consume: https://codeberg.org/andrewrk/async-io-examples/src/branch/main/example8.zig
inline iamge
