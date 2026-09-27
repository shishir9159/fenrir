# Optimising fenrir

`CLAUDE.md` says performance is the first priority and gives four rules for it.
This file is the rest of that sentence: where the time is, how to measure it on
this machine, what is worth trying, what is already right, and what has been
tried and lost.

Read it with `CLAUDE.md`, not instead of it. The rules there — measure first,
benchmark interleaved, prove the output did not change — are binding. What
follows is how to obey them and what to point them at.

**One warning before anything else.** Every hot path named below was found by
*reading* the source, not by profiling it. Reading finds redundant arithmetic;
it does not find where the seconds go. This repository already has one recorded
case of that distinction costing a day: an outline cache with a 95% hit rate
made the program 6% *slower*, because decoding glyphs was 1% of the run. So
treat every item here as a hypothesis with a file and a line number attached,
and confirm it with a profile before editing anything.

## There is no clock

**Out of date, and kept for the reasoning.** There is a clock now: `--time` on
`raster` and on `read`. See "the ledger" at the end for what it says and what
is still missing, which is the `bench` step and a corpus. What follows is why
those were built the way they were.

The first obstacle is not a slow loop. It is that the project cannot currently
carry out its own instructions.

`CLAUDE.md` says to report best-of-N. But there is not one timer in the
program: `nanoTimestamp`, `std.time.Timer` and `Instant.now` return zero hits
across `src/`. The standard workload, `fenrir raster <file> --all --stats`,
prints how many fills, strokes, clips and segments a page had and not one
nanosecond. The nearest thing to a measurement is `replay.Stats.segments`
(`src/gleipnir/replay.zig:207-209`), whose comment calls it "the number that
explains why a page took as long as it did" — a proxy standing in for a clock
that does not exist.

`CLAUDE.md` also says to render every page before and after and compare file
hashes. But `--stats` does exactly one thing: it *skips the PNG write*
(`src/vanagandr/raster.zig:332-335`). The flag on the timing workload is the
flag that suppresses the artefacts you were told to hash, so timing and
verification are two different runs of two different commands, and nothing
guarantees they rendered the same thing.

There is also no corpus. `.gitignore` is a whitelist, so a `.pdf` cannot be
committed without editing it, and all 771 tests are in-file blocks over
synthetic PDFs written as Zig string literals — correctness fixtures, far too
small to time. And `zig build --list-steps` offers `install`, `uninstall`,
`run`, `test` and `spirv`: no `bench`.

### Build the harness first

This is Tier 0 of the worklist and it is not optional. Four pieces, each small
enough to be its own commit:

**A timer.** `--time` on `raster` and on `trace`, printing per-page and total
nanoseconds from `std.time.Timer`. Print it through `ctx.note`, which goes to
stderr (`src/vanagandr/Context.zig:55-57`), so stdout stays byte-diffable for
anything that wants to compare counter output across builds.

**Timing and hashing in one run.** Rather than teaching `--stats` to keep
writing PNGs, have `--time` print a hash of each page's framebuffer directly.
That is strictly better: it removes the PNG encoder from the timing *and* from
the comparison, so the number measures rendering and the hash proves rendering,
from the same run over the same pixels. `Framebuffer.pixels` is a flat `[]f32`
(`src/gleipnir/software.zig:86`), so this is one `Wyhash.hash` over a slice.

**A `bench` step.** In `build.zig`: build `ReleaseFast`, keep the binary under
a stable name so the previous one survives, and run the corpus interleaved.

**A corpus.** The whitelist `.gitignore` forbids committing one, and it should
stay that way — a renderer's test corpus is hundreds of megabytes of other
people's documents. Point at an out-of-tree directory through an environment
variable or a `--corpus` flag. The working set this file was written against is
the real PDFs sitting in `~/Documents`: papers, scans and typeset books, which
between them exercise Flate content streams, embedded CFF and TrueType, JPEG
images and heavy vector line art.

## The method

Turn `CLAUDE.md`'s rules into the commands you actually run.

**Keep both binaries and interleave them.** Comparing across separate
build-and-measure rounds measures CPU frequency drift, not your change.

```powershell
zig build -Doptimize=ReleaseFast
Copy-Item zig-out\bin\fenrir.exe $env:TEMP\fenrir-before.exe
# ... make the change ...
zig build -Doptimize=ReleaseFast

$pdf = "$HOME\Documents\some-paper.pdf"
1..5 | ForEach-Object {
    (Measure-Command { & $env:TEMP\fenrir-before.exe raster $pdf --all --stats }).TotalMilliseconds
    (Measure-Command { & zig-out\bin\fenrir.exe       raster $pdf --all --stats }).TotalMilliseconds
}
```

Report best-of-five, not the mean: the minimum is the run least disturbed by
everything else on the machine, and the mean of a noisy sample mostly measures
the noise.

**Leave `--jobs` alone when you are measuring the rasteriser.** `raster --all`
renders pages on several threads if you ask it to, and it defaults to one
thread precisely so that the standard workload keeps measuring what it always
measured. Six threads turn a change worth two per cent into noise, and the
`interpret`, `canvas`, `fonts` and `render` columns become work done rather
than time waited. Use `--jobs` to measure `--jobs`, and the `wall` line it
prints — not the `time` line, which is the sum of the laps.

**Prove the pixels did not move.** Until `--time` can hash, this needs a
second run with the PNGs written:

```powershell
& $env:TEMP\fenrir-before.exe raster $pdf --all -o before\page.png
& zig-out\bin\fenrir.exe      raster $pdf --all -o after\page.png
$a = Get-FileHash before\page-*.png -Algorithm SHA256 | Sort-Object Path
$b = Get-FileHash after\page-*.png  -Algorithm SHA256 | Sort-Object Path
Compare-Object $a.Hash $b.Hash    # must print nothing
```

The hash set must be **identical**, not close. `CLAUDE.md` is unambiguous here:
an optimisation that alters a pixel is a rewrite and needs saying so. If your
change moves output, it is no longer an optimisation — it is a proposal about
rendering quality, and it needs its own justification, its own before-and-after
images, and its own commit.

**Cross-check the two rasterisers.** `--path both` renders each page through
the stencil pipeline and the analytic one and subtracts them
(`src/vanagandr/raster.zig:425-456`), reporting mean and worst difference in
levels out of 255. It compares two rasterisers inside one build rather than two
builds, so it is not a substitute for the hash diff — but it is the existing
model for what an old-versus-new comparison should print, and it catches a
change that broke one path and not the other.

**Know what you are timing.** `fenrir raster --all` is not a clean
measurement of rendering. Per page it initialises a fresh `DebugAllocator`
(`src/vanagandr/raster.zig:277`) — deliberate, it catches cross-allocator frees
on a corpus run, and worth keeping, but its bookkeeping lands in every profile.
It rebuilds `Glyphs` from scratch (`:280`), so every embedded font program is
parsed again for every page. And it allocates each `Canvas` from `ctx.gpa`,
which is the process-wide arena (`src/main.zig:57`), so `canvas.deinit` is a
no-op and the arena grows by a framebuffer per page. The CLI is arena-shaped on
purpose; just do not mistake its allocation costs for the reader's, which runs
the same code on a real heap.

## Where the time probably is

Three facts about the whole tree, before the individual loops.

**There was no SIMD anywhere.** There is a little now, both in `raster.zig`: a
`@Vector` reduction over one pixel's samples and a sixteen-byte sweep for an
empty run of `cover`. Between them they are worth about two per cent — see the
ledger, which also records that the twenty per cent beside them came from
comptime shape and not from vectors. `@shuffle`, `@setFloatMode`, `@branchHint`
and `@prefetch` still appear nowhere in `src/`.

**Nothing is specialised at comptime.** Out of date, and the one place the
reading was right: `Samples` was read at runtime and `Pass` and `FillRule` were
re-switched *inside the innermost sample loop* although all three are constant
for the whole call. Fixing that is Tier 2 item 5 and it was worth 20%. Nothing
else in the tree is specialised at comptime.

**Nothing inside a page is parallel.** The only `std.Thread.spawn` in the tree
is the reader's background page thread (`src/vanagandr/read.zig:692`). Pages
render one after another on one core, though `src/tyr/raster.zig:194` states
outright that rows are independent.

### Gjöll — decoding, where the unbounded cost is

`Document.streamData` (`src/gjoll/Document.zig:343-353`) is uncached, and it
hands the *document arena* to `filter.decode` (`src/gjoll/filter.zig:128-158`),
which is written for a general-purpose allocator: it `dupe`s the compressed
bytes on entry and then `gpa.free`s each intermediate as it goes. Under an
arena every one of those frees is a no-op. A Flate-plus-predictor stream
therefore leaves three live buffers where one is wanted, `inflate`'s doubling
growth leaves every intermediate capacity behind as well, and none of it is
released until `Document.deinit`.

The project already knows. `Interpreter` keeps a private `stream_cache`, and
the comment on it (`src/gjoll/content/Interpreter.zig:229-238`) says why: a
page that stamps the same appearance stream two hundred times — a table rule,
a bullet, an annotation border — would otherwise inflate the same Flate stream
two hundred times into an arena that is never freed until the document closes.

That diagnosis is right and the cache is in the wrong place. Pushed down into
`Document`, beside the `streams` map that already memoises decompressed
`/ObjStm` containers (`src/gjoll/Document.zig:45-49`), every caller gets it and
the private one can be deleted.

Also in this layer, in descending order of how often it fires:

- `Scanner.array` (`src/gjoll/content/Scanner.zig:238-254`) allocates a fresh
  growing `ArrayList` for every `TJ` operand array — the majority operator on a
  page of text, and one that `showArray` consumes immediately and never
  retains. The surrounding `Scanner` is otherwise exemplary: a one-byte
  dispatch into a fixed operand buffer, with every operand lexed exactly once.
- `Interpreter.State` embeds two `ColorSpace` values **by value**
  (`src/gjoll/content/Interpreter.zig:178-206`), and `q` copies the whole
  struct (`:419-421`). `ColorSpace` carries a `[3]f64` white point and a
  `[4]f64` range that only `.lab` ever reads, so `State` is several hundred
  bytes copied per `q` — which in a real file is once per table cell.
  `space_cache` already interns colour spaces by object number, so these two
  fields can become pointers into arena-owned storage.
- Shadings are re-loaded on every reference (`:882-914`), and a type-0 sampled
  function re-inflates its sample table each time, so a gradient referenced
  from ten places is inflated ten times.
- Every resource lookup re-resolves its sub-dictionary: `selectFont`,
  `extGState`, `doXObject`, `colorSpace` and `patternPaint` each begin with a
  `doc.get(resources, ...)` on every occurrence, though the six sub-dictionaries
  are constant for the duration of one content stream.
- `xref.indexObjectStreams` parses each recovered object twice
  (`src/gjoll/xref.zig:552,565`) — only on the reconstruction path, which
  `Document.open` enters whenever a table parses but does not reach pages.

### The JPEG decoder — the clearest raw-throughput win

`src/gjoll/filter/jpeg.zig` has three stacked costs, each independently large,
and they compound on exactly the documents that are slowest already: scans.

The bit reader extracts **one bit at a time** (`:129-161`), and `bit()` branches
on the accumulator being empty and then on `0xFF` byte-stuffing, per bit.
`bits(n)` loops over it. Huffman decoding then walks code lengths 1 through 16
a bit at a time (`:182-196`). And the inverse DCT is the textbook separable
double loop (`:590-612`): 512 multiply-adds a pass, 1024 a block, about sixteen
multiplies a pixel, where AAN is roughly five multiplies and twenty-nine adds
per eight-point pass.

Most importantly there is **no all-zero-AC shortcut**. A flat 8×8 block — most
of any scanned page, and most of the smooth regions of any photograph — runs
the full 1024 operations to produce sixty-four copies of one number. That check
is about ten lines and is very likely the largest single win in this file. Do
it first, measure it, and only then consider the Huffman table, the
word-refilled bit reader and AAN, in that order and each measured on its own.

### Gleipnir — the pixel loops

`Canvas.rasterTriangle` (`src/gleipnir/raster.zig:678-782`) is what the CPU
workload turns on. The module header records that the fan triangles overlap
enormously, so its work is proportional to the *summed area of the fan* rather
than to the area of the path — which is why this one function dominates.

- **The edge functions are not incremental.** The doc comment at `:670` says
  they are "carried incrementally across x", but `:727` recomputes
  `e.dx * (fy - e.ay) - e.dy * (fx - e.ax)` from scratch, for all three edges,
  at every pixel. The affine step that would make the comment true is already
  written down fifteen lines below it, at `:865-874`.
- **`clipAt` re-tests what is already known.** The pixel loop calls it at
  `:715` and it runs a full `Box.contains` (`:357-361`) — but `area_px` was
  intersected with the clip box at `:695`, so `contains` is provably true for
  every pixel in the loop, and the row base is invariant in x.
- **`allClear` is a scalar byte loop** (`:849-853`), run once per pixel per
  cover triangle over that pixel's eight contiguous stencil bytes. With the
  stencil laid out one byte per sample this is one eight-byte load and a
  compare.
- **`inside()` re-derives what `Edge` already holds** (`:859-861`): for every
  sample that needs the exact test, `edgeInside` recomputes the same `dx` and
  `dy` that `Edge.of` precomputed, three times per sample.

Around it, `resolve` (`:636-662`) sweeps the path's whole bounding box a byte
at a time looking for non-zero coverage, and the comment at `:738-739` notes
that an `o` fills about a third of its box and a comma a twentieth — so most of
that sweep finds nothing. `blend` (`:796-822`) re-clamps and re-encodes a
colour that is constant for the entire fill; in `.srgb`, the page rasteriser's
default (`:113`), `encode` is the identity and this costs only a branch, but in
`.linear` it is three `std.math.pow` calls (`src/gleipnir/rect.zig:97`) per
pixel. `pushClip` (`:401-408`) does an integer divide by 255 per pixel.

Underneath all of it the framebuffer is four `f32` per pixel
(`src/gleipnir/software.zig:86,93`) — sixteen bytes, so a page at 2× is a 31 MB
working set and every full-box sweep is bound by memory bandwidth rather than
by arithmetic. That is a deliberate choice, because this file is the oracle the
GPU shader is checked against, and narrowing it changes pixels. See Tier 3.

Elsewhere in Gleipnir:

- `stroke.disc` (`src/gleipnir/stroke.zig:301-310`) calls `@cos` and `@sin` per
  vertex, with a divide per vertex, for every round join and cap — up to 128
  vertices each, and joins are drawn at every vertex of a flattened curve.
- `stroke.signedArea` (`:347-354`) uses `% v.len` on a slice whose length is
  three or four at every call site.
- `slug.rayAlongX` and `rayAlongY` (`src/gleipnir/slug.zig:746-781`) gather
  through two levels of indirection per curve per pixel, copy a 24-byte struct
  via `swapped()` purely to exchange axes, and recompute per pixel the very
  `reach` value the band was already sorted by (`:391-394`).
- The cubic flatteners divide by `n` once per emitted segment
  (`src/gleipnir/path.zig:309`, `src/tyr/raster.zig:223`) where `1/n` is
  loop-invariant, and evaluate the full Bernstein form per `t` where uniform
  steps are the case forward differencing was invented for.

### Týr — glyphs and font programs

`src/tyr/raster.zig` is the signed-area scan converter, and two loops in it
matter. `drawLine` accumulates a constant `d * s` across a contiguous `[]f32`
run in a scalar loop (`:345`) — the textbook vectorisable case, and a long run
for the near-horizontal edges that serifs and bar tops are made of. `fill`
(`:196-206`) runs a serial prefix sum per row, and its own comment points out
that the rows are independent.

`src/tyr/backend/truetype.zig` declares three fixed arrays of `max_points =
10_000` inside `simple()` (`:591,614,615`) — ten kilobytes of flags plus forty
each of x and y, a **90 KB stack frame per call**, through a recursion up to
five deep for composites. `n_points` is known at `:580-583`, before the arrays
are needed, and a typical glyph has thirty points.

Finally, `src/vanagandr/glyphs.zig:160-174` re-runs the encoding chain and
re-decodes the outline for every glyph *occurrence* rather than every distinct
glyph — a full `glyf` parse or Type 2 charstring interpretation per character
on the page. Read the graveyard before acting on that one.

### Per-page work that should be per-document

Both the reader and the benchmark rebuild `Glyphs` and `Images` for every page
(`src/vanagandr/read.zig:1099-1103,1132-1136`;
`src/vanagandr/raster.zig:280-284`). Every embedded font program is parsed
again, and every shared image — a letterhead, a logo, a figure repeated through
a chapter — is decoded again, once per page. Both are per-document objects
wearing a per-page lifetime.

The reader also re-runs the whole interpreter on a zoom change
(`src/vanagandr/read.zig:1037`), because the cache slot is keyed on zoom
(`:487`) — although the display list is page-space and zoom-independent, which
`recordPage` states in as many words at `:1120-1123`. A CPU zoom therefore
re-lexes, re-decodes and re-interprets the content stream to build a display
list identical to the one it just discarded.

**Measured since, and both smaller than they read.** The per-page `Glyphs` was
the one worth fixing and is fixed. The re-interpretation on a zoom is real and
costs 0.6% of the zoom; see the graveyard. What this section did not name, and
what turned out to dominate, is in the ledger under the canvas.

## The worklist

Ranked by expected payoff against risk. Every item is a hypothesis: profile
first, and if the profile disagrees, write that down in the graveyard and move
on.

### Tier 0 — the harness

Everything in "Build the harness first". Nothing below can be honestly
attempted until a run prints a time and a hash. This is not throat-clearing:
without it, every claim in a commit message is a guess.

Half done. The timer and the hash exist and share one run — `raster --time`,
and `read --time` for the startup stages. The `bench` step and the corpus flag
do not, so interleaving two binaries is still done by hand, the way "the
method" describes.

### Tier 1 — unbounded or repeated work

These are not micro-optimisations. Each one removes work that should never have
happened, and their effect grows with the size of the document.

**Done.** All four were attempted; two landed, one was already covered, and one
was measured and rejected. Numbers in the ledger, and the item that lost is in
the graveyard. What the tier actually turned up is that the largest repeated
work in the tree was in none of the four: `fenrir raster` gave every page's
canvas the CLI's arena, and an arena does not free.

1. ~~**Cache `Document.streamData` by object number, and decode off the
   arena.**~~ Landed, keyed on the `Stream`'s address rather than on an object
   number, which is the same identity and also covers the streams that have no
   number. `Interpreter.stream_cache` is gone. Halves the interpret column on a
   long document and is invisible in the total, because interpreting is under
   one per cent of a page.
2. ~~**Hoist `Glyphs` and `Images` to per-document.**~~ The half that mattered
   is `glyphs.Cache`, which landed earlier and is in the ledger. The other half
   is argued against below rather than done: a decoded image is tens of
   megabytes, and per-document is exactly the lifetime this pass just spent its
   time taking *away* from that kind of memory.
3. ~~**Add the DC-only shortcut to the JPEG inverse DCT.**~~ Landed. **7% off
   an image-heavy document**, bit-exact, and the biggest single win of the
   tier.
4. ~~**Cache the `DisplayList` per `(buffer, page)`.**~~ Written, measured,
   reverted. See the graveyard: it saves 0.6% of a CPU zoom.

**What is left here.** Two things, both memory rather than speed, and both
bigger than the items above were:

- **A `Document` that does not retain every page.** After the canvas fix a
  519-page scan still climbs to 3.5 GB, and all of it is the document arena:
  every page's decoded content stream and every image's bytes live until the
  file is closed, because the library's ownership rule is that nothing handed
  out needs freeing. Bounding it means changing that rule, which is a design
  change and not an optimisation.
- **Per-document decoded images.** Only worth doing behind a cache with a byte
  budget and an eviction policy, for the reason in item 2.

### Tier 2 — the pixel loops, bit-exact and contained

**Mostly done, and the largest win in the file so far: 19% off a paper, with
every hash unchanged.** Numbers in the ledger. Items 5, 6, 7 and 8 landed
together as the same loop; item 9 is untouched and now looks too small to
bother with against what is left.

5. ~~**Comptime-specialise `rasterTriangle` on `(pass, rule, samples)`.**~~
   Landed, and it was the win it was billed as. `rasterTriangle` is now a
   three-level `inline` switch over one `triangle` body, so `positions` is a
   comptime array, the sample loop unrolls, and the pass and the rule are
   folded away rather than tested per sample.
6. ~~**Make the edge functions genuinely incremental in x**, and hoist the clip
   row base out of the pixel loop.~~ Landed, but *not* incrementally: the row
   is `d = base - dy*x`, one fused multiply-add rather than a running total.
   Carrying `d` across a row would accumulate error the `margin` then has to
   absorb, and this form is the same instruction count with no drift at all.
   The clip row base is hoisted, and with it the bounds test `clipAt` made:
   `area_px` is already intersected with the clip box, so every pixel in the
   loop is inside it by construction.
7. ~~**Vectorise the three obvious loops.**~~ Two of them: `allClear` is a
   `@Vector(n, u8)` reduction now that `n` is comptime, and `resolve` sweeps
   `cover` sixteen bytes at a time and walks only the blocks that hold
   something. `tyr/raster.zig`'s constant-`d * s` span is still untouched.
8. ~~**Hoist the loop-invariants.**~~ The colour encode is out of `blend`:
   `resolve` and `fillSlug` encode once per path into an `Encoded` rather than
   once per covered pixel. The `1/n` in the cubic flatteners is still there.
9. ~~**Replace the small wastes**: `disc`'s per-vertex `@cos`/`@sin` with
   incremental rotation, `signedArea`'s `%` with a rotated walk, `pushClip`'s
   divide by 255 with the reciprocal form, and TrueType's 90 KB of stack arrays
   with a scratch buffer on the face.~~ **Dropped, not done.** The ledger's
   last section says why: none of the four is in a per-pixel loop, and the two
   changes of this kind that *were* made came to 1.9% together. Take one only
   if a profile names it.

**The one hazard to name out loud.** Any change to the per-sample test must
reproduce `edgeInside`'s top-left rule *exactly*. The cover quad is two
triangles sharing a diagonal, and a sample on that diagonal must land in
exactly one of them; get it wrong and the diagonal appears as a seam down every
filled shape on the page. `Edge.margin` exists for precisely this, because the
bracket and the exact test are the same arithmetic in a different order and can
disagree in the last bits. Item 6 reassociated exactly that arithmetic and got
away with it because the margin is a hundred epsilons wide and the reassociated
form is within one; the hash diff is what said so, not the reasoning. If you
touch this, the hash diff is not a formality — it is the only thing standing
between you and a subtly wrong renderer.

**And one that cost an afternoon.** The first hoisted clip row was
`(y - y0) * clip_w - x0`, indexed with `+ x`. That is right modulo two to the
sixty-four and wrong as a `usize`: on the first row of any clip whose box does
not start at x = 0 it underflows. `ReleaseFast` wraps, so it rendered correctly
and every hash matched; the debug tests all used a full-page clip, so they
passed too. It took a `ReleaseSafe` screenshot to find it. Index a row from the
box's own origin — `+ (x - x0)` — and do not let a bench-and-hash run stand in
for the safe build the finishing section asks for.

### Tier 3 — structural, or changes output

10. A reusable scratch buffer for `Scanner.array`; indirect `ColorSpace` in
    `Interpreter.State`; a shading cache keyed by object number; hoisting the
    resource sub-dictionary lookups out of the operator handlers.
11. Packing `(reach, index)` into the slug bands so the early exit needs no
    gather and the sort needs no comparator indirection.
12. **Threads.** ~~Pages.~~ Landed as `raster --all --jobs N`: **4.4× to 5.0×
    on six cores**, every framebuffer hash unchanged on all 28 documents.
    Numbers in the ledger. What made it safe is that no page is rendered any
    differently — a page still gets one canvas, one transform and one thread —
    so there was nothing to get subtly wrong about the top-left rule or the
    stencil. The sharing was the whole problem and the answer was not to
    share: each thread opens its own `Document` over the same bytes, because a
    `Document` memoises as it reads and a lock around it would have put every
    image decode on every thread's critical path.

    **Rows are still to do, and they are the half a reader would feel.**
    `src/tyr/raster.zig:194` says rows are independent, and a person waiting
    through a zoom is waiting on one page. But splitting a page into bands
    moves the page transform by an integer number of device pixels, and
    `a*x + b*y + (f - y0)` is not `(a*x + b*y + f) - y0` in floating point: the
    hashes move. By this project's own rule that makes it a rendering change
    and not an optimisation, so it needs the argument Tier 3 item 13 needs.
    Splitting the *display list* by band instead, and giving each thread the
    unmodified transform and a clip to its own rows, is the version that keeps
    the arithmetic and is worth trying first.
13. **Narrowing the `f32` framebuffer.** Sixteen bytes a pixel is what makes
    the sweeps bandwidth-bound, and eight or four would halve or quarter that.
    It also changes pixels, so by this project's own rule it is a rewrite and
    not an optimisation, and it costs the file its standing as the oracle the
    GPU shader is diffed against. Propose it as a rendering change or not at
    all.

## Leave these alone

This section matters as much as the worklist. Several parts of this codebase
are already the right answer, and three of them carry written reasoning about
why the obvious improvement is wrong. Changing them without a profile that
specifically indicts them is how an optimisation pass makes a program slower.

**The Vulkan frame loop.** `src/lyngvi/` is the best-optimised part of the
tree. Two frames in flight, with the reasoning stated. Instance buffers mapped
once at creation and never unmapped, so a frame is one `memcpy` into memory the
GPU reads where it lies. No per-frame heap allocation at all. One draw call per
layer, the quad from `gl_VertexIndex`, the clip carried in the instance rather
than in `vkCmdSetScissor`. Command *pool* resets with transient pools. Dynamic
viewport and scissor, so a resize does not rebuild a pipeline mid-drag.
Render-finished semaphores owned per swapchain image rather than per frame —
the bug most first Vulkan renderers ship. `oldSwapchain` passed on recreate. No
`vkDeviceWaitIdle` anywhere in the frame path. And `PathRenderer.upload` is
generation-gated (`src/lyngvi/PathRenderer.zig:405-412`), so a stationary
reader uploads nothing and a scroll uploads placements rather than curves.

The remaining stalls in that layer are all outside the steady state: texture
creation, atlas growth, the startup placeholder, and the snapshot path. Each is
commented with why the wait is safe where it is.

**`Font.cidWidth`'s linear scan** (`src/gjoll/content/Font.zig:166-174`). The
comment records that a linear scan beats the cache miss of anything cleverer
until it does not, and that it has not yet. That is a measured decision. It is
worth *re-measuring* on a large CJK font, where `/W` can hold hundreds of
ranges — but not worth changing on the strength of how it looks.

**`Scanner`'s one-byte dispatch and `Lexer`'s borrow-from-source fast paths.**
Names and literal strings are returned as slices of the file buffer whenever no
escape had to be resolved, and the operand buffer is fixed-size. The header on
`Scanner` explains why `Parser` is deliberately not reused. This is the design
that makes content-stream parsing cheap; do not add an allocation to it.

**Gelgja.** A struct-of-arrays display list where a path is a range into shared
arrays rather than an allocation, and `paint.zig` allocates nothing at all. The
only thing worth doing here is reserving a capacity floor in `Builder.init`, or
reusing one `Builder` across pages on the rasterising thread, since a fresh
interpreter per page means the amortisation never happens.

**Þviti's frame arena.** Reset with capacity retained
(`src/thviti/UI.zig:270`), with keyless boxes — most of a tree — allocated from
it and only stateful boxes in the persistent map. Text shaping is cached by
`(FontId, text)`. The immediate-mode call sites are not the problem.

## What must not break

An optimisation that violates any of these is not finished, however fast it is.

- **The stencil is clean after every page.** `src/vanagandr/raster.zig:303-305`
  checks it on real documents, not only on shapes a test thought of. A page
  that leaves the stencil dirty has drawn something wrong.
- **The top-left rule.** See the hazard note in Tier 2.
- **The clip box means what it says.** It is not an optimisation of the common
  case; `src/gleipnir/raster.zig:245-266` records that a scatter plot with
  1,635 two-point clips costs five gigabytes of memory traffic and three and a
  half seconds without it.
- **`zig build test` is green.** All 771 of them, before committing.
- **`-Dsqlite=false -Dlua=false` still compiles**, and its tests skip cleanly.
- **A ReleaseSafe build and one cross-compile** (`zig build
  -Dtarget=x86_64-linux-gnu`) if the change touches the platform layer or the
  build.
- **No new dependencies.** Not for parsing, UI, fonts, images or maths. A SIMD
  helper library is a dependency.
- **Zig 0.16 std only**, checked against the installed std source rather than
  recalled — it moves, and the vector and `@branchHint` APIs are exactly the
  kind of thing that has moved.
- **Wayland is compile-verified only.** There is no Linux on this machine.
  Never claim it was run.

## The ledger

What has been measured, on what, and what it came to. Kept because a number
nobody can reproduce is indistinguishable from a refactor.

The machine is the one this file was written on: Windows 11, GTX 1650 SUPER,
`-Doptimize=ReleaseFast`, both binaries kept and run interleaved, best of five
or six. The workload is `raster --all --stats --time` unless it says otherwise,
and every claim below was checked with the framebuffer hash `--time` prints.

**Tier 0 is done.** `raster --time` prints per-page and total nanoseconds split
four ways — interpret, canvas, fonts, render — and a Wyhash of each page's
`f32` framebuffer, folded in page order into one hash for the run. Timing and
verification are now one run over one set of pixels, which is what the method
section asks for. `read --time` prints the startup stages. There is still no
`bench` step and no committed corpus; the corpus used here is the 28 PDFs in
`~/Documents`.

**Where the time actually is.** On *Pretrained Transformers*, 26 pages at
96dpi, 2250ms total: render 2030ms, canvas 190ms, fonts 25ms, interpret 16ms.
So Gleipnir is **90%** of the run and the whole of Gjöll is under one per cent.
Note the canvas column, which this file did not predict: allocating and
clearing fourteen megabytes of `f32` per page is 8% of the run, more than
interpreting and binding fonts put together. That is the `f32` framebuffer of
Tier 3 item 13 showing up on the clock rather than only in the reasoning.

**Item 2, hoisting face construction: correct but small.** A `glyphs.Cache`
keyed on the font dictionary's object number, one per document. On the paper
above the fonts column fell from **25.3ms to 6.2ms**, a four-fold cut with a
25-miss-in-26-pages hit rate — and the total moved from 2256ms to 2250ms,
which is inside the noise, because fonts were only one per cent to begin with.
Kept for the reader, where it is a per-page latency the eye can see rather than
a column in a batch run, and because it is the right shape. But recorded here
as what it measured: **not** a throughput win. Hashes identical on all 28
documents.

The caution in "one warning before anything else" was right twice over. The
`fonts` column originally read 219ms and looked like a tenth of the run; it was
the canvas allocation hiding inside the same lap. Split the lap before
believing the label.

**Startup: 896ms to 709ms, best of six, interleaved.** Not a faster anything —
the same work in a different order. `read --time` showed startup was device
362ms, swapchain 353ms, first page 223ms, everything else under 30ms: three
quarters of it in the driver, and the page rasterised strictly after it for no
reason. The layout is settled and the rasterising thread started as soon as the
window exists, so page one is finished and waiting by the time there is a
texture to upload it to. "first page" now reads 0.00ms — the window comes up
with the page already on it instead of showing blank paper for a fifth of a
second. Only taken when `backend` is already `.cpu`; see the comment at the
call for the race that gates it.

**Tier 1, measured.** Three documents carry the argument: *Pretrained
Transformers* (26 pages, text), *Nanite_2021* (155 pages, 333 decoded images),
and *kolmbook-eng-scan* (519 pages, a scan). Every run below is
`raster --all --stats --time`, best of five or six, binaries kept and
interleaved, and both orderings run because on this machine a few minutes of
load moves the total several per cent — larger than most of what is being
measured.

**The canvas was on the CLI's arena, and an arena does not free.** This was not
on the worklist and is the largest thing in it. `fenrir raster` passed
`ctx.gpa` — the command arena, whose `deinit` is a no-op — to `content.page`,
`Canvas.init` and `replay.render`, so every page's fourteen megabytes of `f32`
stayed resident for the life of the process. The scan peaked at **8,296 MB**.
Giving `one` its own arena, reused across pages and `reset(.retain_capacity)`
behind each one, takes that to **3,476 MB**, a 58% cut, and takes the canvas
column on the scan from 3,160–4,261 ms to 2,148–2,276 ms.

Two wrong answers were built and measured first, and both are worth recording
because both looked obviously right:

- *A `DebugAllocator` for the page.* **2.5% slower**, and the cost showed up in
  the **render** column, not the canvas one — the rasteriser allocates per path
  and a checking heap under that is not free. The `DebugAllocator` is still
  there for `Glyphs` and `Images`, where it is not about memory but about
  catching a free against the wrong allocator.
- *A fresh arena per page.* Still **2.5% slower**. A new arena hands back cold
  pages and pays the fault on all fourteen megabytes again every page. Only
  retaining the capacity — same allocator, same warm memory, bounded at the
  largest page instead of the sum of them — both frees the memory and keeps the
  speed.

**Item 1, `streamData` memoised and decoded off the arena: correct, and a
memory fix that this corpus does not reward.** Keyed on the `Stream`'s address,
which is the same identity as an object number, since a stream is parsed once
into an arena that never reuses an address — and it covers direct streams too.
`Interpreter.stream_cache` deleted. The interpret column on the scan fell from
**760–871 ms to 343–375 ms**, less than half; the total did not move, because
interpreting is 0.6% of a page. Peak RSS with and without it, both on top of
the canvas fix: **3,474 MB and 3,476 MB** — that is, nothing. The arena was
never where the gigabytes were. Kept for the halved column, for deleting the
workaround, and because the six callers outside the interpreter now get the
memoisation too.

**Item 3, the DC-only JPEG inverse DCT: the win of the tier.** A block whose
only non-zero coefficient is the DC term is a flat 8×8 patch, and both IDCT
passes collapse to two multiplies and a `memset`. On *Nanite_2021*, best of
four in each ordering, **41,131 ms to 38,217 ms — 7.1%**, and t1e won every one
of the four interleaved pairs. Bit-exact rather than nearly so: adding zero to
a finite float is exact and `idct_table[u][0]` does not depend on `u`, so
writing the shortcut as the same two multiplies in the same order reproduces
the loops exactly. Hash unchanged on all 28 documents.

**All 28 documents were hashed before and after, and all 28 are identical.**

**Tier 2, measured: 19% off a paper, and the largest win recorded here.** Four
items, one loop, two commits, all of it inside `rasterTriangle` and `resolve`.
The workload is *Pretrained Transformers*, 26 pages at 96dpi,
`raster --all --time`, both binaries kept and run interleaved, best of five in
each ordering.

| | best of five | render column |
|---|---|---|
| before | 2,603.93 ms | 2,440 ms |
| after | 2,109.34 ms | 1,889 ms |

**19.0% on the total and 22.6% on the render column**, and the new binary won
all five interleaved pairs — the margin is far wider than the few per cent this
machine drifts by. Hash `bf68db5063ccf734` before and after, and **all 28
documents in the corpus hash identically**.

Split between the two commits, on the same workload:

- *One triangle raster per pass, rule and sample count* (item 5, with 6 and 7's
  `allClear` along for the ride, because the vector reduction needs the
  comptime `n`): **2,638.77 ms to 2,099.16 ms, 20.4%**. This is essentially the
  whole of it. The file predicted it would be "the highest-value change in
  Gleipnir and the one that unlocks the rest", and for once reading the source
  and profiling it agreed.
- *Encode a fill colour once and skip empty cover rows* (items 7 and 8):
  **1,942.41 ms to 1,904.99 ms, 1.9%**, winning four of five pairs. Small, real,
  and worth having only because it was already open; nobody should go looking
  for another one like it.

What the split says is worth writing down. The win was not the vectors and it
was not the hoisting — those are together a fortieth. It was deleting two
branches and a runtime slice from a loop that runs eight times per pixel per
triangle, which the compiler could then unroll. On this renderer the thing that
pays is giving the optimiser a loop whose shape it knows.

**Tier 3 item 12, pages on threads: 4.4× to 5.0× on six cores, and every
hash identical.** `raster --all --jobs N`. The machine has six cores; `--jobs
0` asks for one thread per core. Wall clock, best of three in each ordering,
both binaries kept and interleaved:

| | 1 thread | 6 threads | |
|---|---|---|---|
| *Pretrained Transformers* (26 pages, text) | 1,829 ms | 415 ms | **4.4×** |
| *Nanite_2021* (155 pages, 333 images) | 29,169 ms | 5,737 ms | **5.0×** |
| *kolmbook-eng-scan* (519 pages, a scan) | 35,345 ms | 6,999 ms | **4.9×** |

**All 28 documents were hashed at one thread and at six, and all 28 agree** —
and the PNGs of a fourteen-page paper are byte-identical file for file, not
merely equal in the framebuffer. That is by construction rather than by luck:
a page is rendered by exactly one thread, through the same `one`, with the
same canvas, transform and order of operations it has always had. Only *which*
thread and *when* changed. The per-page hashes are folded into the run's hash
in page order afterwards, and each page's report is buffered and played back
in page order, so `--stats` output stays byte-diffable across builds.

Memory is the cost, and it is not the one the arithmetic suggests. Peak RSS:

| | 1 thread | 6 threads |
|---|---|---|
| *Nanite_2021* | 105 MB | 332 MB |
| *kolmbook-eng-scan* | 3,443 MB | 3,571 MB |

Six page arenas instead of one is six framebuffers, which is the whole of the
Nanite figure. The scan barely moves, and the reason is the one that made
per-thread documents affordable: the gigabytes there are decoded pages held in
the document arena, and six documents rendering a sixth of the pages each
retain between them what one document rendering all of them did.

Two things were considered and not built. *One shared `Document` behind a
mutex* looked cheaper — interpreting is 0.6% of a page — until you notice that
images are decoded lazily *during* the render, through the document, so the
lock would have serialised the expensive half of the image-heavy case. *One
document per thread, opened over duplicated bytes* was the same design with a
copy of a hundred-megabyte file per thread in it; `Document.openBorrowed` is
four lines and removes the copy.

**What is left, in the order the clock now argues for.** Everything worth doing
is in Gleipnir, and the non-Gleipnir items that looked promising are measured
and small.

**Tier 2 is spent, and item 9 is not worth doing.** It was never large, and
the ledger now says how large by analogy. Items 7 and 8 — real, correct, and
exactly the same *kind* of change, made while the loop they were in was
already open — came to **1.9% between them**, and the note under them says
nobody should go looking for another one like it. Item 9's four are all
further from the hot loop than those two were. `disc`'s `@cos`/`@sin` run per
round join, not per pixel. `signedArea`'s `%` runs on a slice of three or
four. `pushClip`'s divide by 255 is per clipped pixel, and a clip covers a
small part of a page. TrueType's 90 KB stack frame is one subtraction of a
stack pointer, inside the glyph decode the graveyard already measured at 1% of
the run — the same 1% that made an outline cache with a 95% hit rate a 6%
*loss*. Four edits of that size, each needing its own interleaved benchmark
and its own hash diff, against a render column that is still 90% of the whole
run: the machine's own drift between two sessions is wider than the answer.

What costs now is that a page is one thread's work, and after Tier 2 the
render column is still 90% of the run. Threading pages took 4.4× to 5.0× off a
batch run without touching a line of Gleipnir. Rows are the same argument
pointed at the thing a reader actually waits for, and Tier 3 item 12 says what
stands in the way of them. Item 13's framebuffer width has a number against it
too: the canvas column is 8% of a run, and it is 8% because sixteen bytes a
pixel have to be allocated, faulted and cleared. Tier 1 items 1 and 3 remain
memory fixes rather than speed ones and should be argued as such.

## The graveyard

Ideas that were measured and lost. Append to this when something of yours does,
with the number you measured — a rejected idea with a number attached is worth
more to the next person than a vague warning.

- **A glyph outline cache.** Reached a 95% hit rate and made the program **6%
  slower**, because decoding glyphs was 1% of the run and the cache's lookups
  and misses cost more than the decode it avoided. This is why the
  per-occurrence outline re-decode at `src/vanagandr/glyphs.zig:160-174` is
  listed as *measure first* rather than as a win. Note what it does and does
  not say: it is an argument against caching *outlines*, not against hoisting
  *face construction*, which is item 2 and a different quantity entirely.

- **A `DisplayList` cache per `(buffer, page)`**, Tier 1 item 4. Written and
  reverted. The premise is right — the reader keys its cache slot on zoom, and
  a display list is page space, so a CPU zoom really does re-lex, re-decode and
  re-interpret a content stream to rebuild the list it just threw away — and
  the premise is worth **0.6%**. Interpreting a page is 0.53 ms on a paper,
  0.33 ms on the Nanite slides and 0.66 ms on a scan, against 79 ms, 250 ms and
  75 ms to render one. A person waiting through a zoom is waiting on Gleipnir,
  and the fix for that is to raster faster, not to interpret less. Item 1 had
  already halved the half of it that was Gjöll. Recorded rather than kept,
  because the next person will read the same code and think the same thing.

- **A `DebugAllocator` for the page, and a fresh arena per page.** Both 2.5%
  slower than the arena that never freed. See the ledger; the shape of the
  answer was to keep the arena and change only its lifetime.

## Finishing

`zig build test`, then a ReleaseSafe build, then a cross-compile if the change
touched the platform layer or the build.

Then commit the way this repository commits: one feature per commit, under
about 300 lines, a message under 72 characters that reads like a changelog line
(`fewer sample tests and allocations per filled path`), at most three commits a
day with plausible timestamps at `+0600`, no fluff, no filler, and no context
the diff already shows.

Keep the benchmark out of the message itself — a commit message here is one
line, and the diff shows the rest. But do not lose the number: record
somewhere what was measured, on which file, best of how many runs, and that
the hashes matched. An optimisation nobody can reproduce is indistinguishable
from a refactor.
