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
| **Gjöll** | `src/pdf/` | parser: objects, xref, filters, page tree | the boulder the fetter is anchored to | done |
| **Gelgja** | `src/gelgja/` | the display list: parser output, renderer input | the cord threaded through the rock | interface done |
| **Gleipnir** | `src/gleipnir/` | rasteriser: content-stream interpreter, Vulkan backend | the ribbon that holds | — |
| **Týr** | `src/tyr/` | fonts: outlines, encodings, glyph atlas | the hand it cost | — |
| **Lyngvi** | `src/lyngvi/` | platform: window, input, surface | the island it happened on | — |
| **Vánagandr** | `src/cli/` | the command-line tool | "monster of the river Ván", his other name | done |

Directory and identifier names are ASCII-folded — `gjoll`, `tyr`,
`vanagandr` — and the diacritics live only in prose. Zig will accept UTF-8
identifiers; build systems, shells, and filesystems across three platforms
are less reliable about it, and this is not the hill.

`src/pdf/` and `src/cli/` still carry their descriptive names; the rename to
`gjoll` and `vanagandr` is mechanical and has not landed yet.

**Status: milestone 3, plus Gelgja's interface.** Gjöll is done: the container
is fully readable and the page tree resolves into pages with their effective
geometry. Gelgja's display list, builder, and trace backend are written and
tested; nothing produces one yet, because the interpreter that will is
milestone 4. Gleipnir, Týr and Lyngvi are not started.

## Building

```
zig build              # zig-out/bin/fenrir
zig build test         # 110 tests
zig build run -- info file.pdf
```

Requires Zig 0.16.0.

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
```

`fenrir extract file.pdf --page 1` prints a decoded content stream — the
actual graphics language a page is written in, and the input to milestone 4.
`fenrir xref --verify` checks that every offset in the table really points at
its own `N G obj` header, which is the single most useful signal about
whether a file is well-formed.

## Layout

Dependencies run strictly one way. Nothing below `Document` knows that
documents exist, which is what lets the same parser read the file body, the
inside of an object stream, and a content stream. Nothing at or below
`Document` knows what a page is.

```
src/
  root.zig                  public library surface
  main.zig                  CLI entry and dispatch
  cli/                      Vánagandr
    Context.zig             allocator, Io, and the two writers
    info.zig  dump.zig  pages.zig  xref.zig  extract.zig
  pdf/                      Gjöll
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
  gelgja.zig  gelgja/       Gelgja
    geom.zig                points, matrices, bounds, path verbs
    paint.zig               colour, stroke parameters, blend modes, layers
    DisplayList.zig         DrawCmd and the recorded list
    Builder.zig             the recording API the interpreter will call
    trace.zig               a display list as diffable text
```

Gelgja imports neither the PDF layer nor any graphics API, which is what lets
its tests run with no document and no GPU.

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
  backend. Nothing produces a display list yet -- the interpreter is next --
  but the interface it must target is fixed and tested.

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
- Everything above the page: content-stream interpretation, fonts, colour,
  rendering, UI.

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

Still to come: **a CPU rasteriser to PNG**, pixel-diffed against `mutool draw`
or `pdftoppm`. That is the ground truth, and it becomes the regression suite.

There is deliberately no SVG backend. The browser was never the goal; the goal
was a renderer trustworthy enough to bisect against, and SVG stops being
trustworthy exactly where PDF gets hard — blend modes, soft masks, shading
types 4–7, text rendering modes, dash phase.

### 5–6. Lyngvi and Gleipnir — window and pixels

A platform layer of roughly fifteen functions: open a window, drain events
into an arena, block until input, hand back a Vulkan surface. Win32 first,
xcb second, and the xcb backend stubbed from day one so the abstraction stays
honest rather than quietly Win32-shaped.

Then one Vulkan pipeline: instanced quads with a rounded-rect signed distance
field, per-corner radii and colours, border thickness, edge softness. That
single primitive draws every panel, button, scrollbar, shadow, and — with the
source rect pointing into a glyph atlas — every character. PDF paths need a
second pipeline, stencil-then-cover, which handles nonzero and even-odd
winding without triangulating anything.

### 7. Týr — fonts

TrueType `glyf` and CFF Type 2 charstrings for outlines; `/Encoding` and
`/Differences` and CID CMaps for code-to-glyph; `/Widths` and `/W` for
metrics, which come from the PDF and not the font file, and win when the two
disagree; `/ToUnicode` for selection and search, which is a third mapping
again. FreeType via `@cImport` first so the rest of the viewer can be built,
replaced later.

### 8. The UI

**Decided: immediate-mode call sites over a retained box cache**, following
the RAD Debugger's `ui` layer. Not either pure form.

"Immediate versus retained" conflates two independent things: the shape of the
call site, and whether per-widget state survives between frames. Dear ImGui
picks immediate for both and pays in awkward animation, awkward focus order,
and layout that lags a frame. Qt and GTK pick retained for both and pay in
ownership, invalidation, and diffing. The hybrid takes immediate call sites
and retained *state*: boxes live in a hash table across frames, keyed by a
64-bit hash of a string plus a parent seed, carrying hover and active
animation, focus, and scroll offsets. You write immediate-mode code and get
persistent state for nothing.

Sizing is semantic — pixels, text content, percent of parent, sum of children
— each with a strictness, solved in passes: independent sizes, then
upward-dependent, then downward-dependent, then violations, then
relative-to-absolute. Because layout is a separate pass over a tree that
already exists, there is no one-frame lag.

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
