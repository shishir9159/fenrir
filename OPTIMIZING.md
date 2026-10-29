# Optimising fenrir

`CLAUDE.md` makes performance the first priority and sets the rules: measure
first, benchmark interleaved, prove the output did not change. This file is
how to obey them here: where the time is, what is worth trying, what is
already right, and what has been tried and lost.

**Every open item below is a hypothesis.** Most were found by reading the
source, and reading finds redundant arithmetic, not where the seconds go. An
outline cache with a 95% hit rate once made this program 6% *slower*, because
decoding glyphs was 1% of the run. Profile before editing anything.

## The harness

`raster --time` splits each page into interpret, canvas, fonts and render, and
hashes the `f32` framebuffer in the same pass, folding the per-page hashes in
page order. Timing and verification are one run over one set of pixels.
Output goes to stderr, so stdout stays byte-diffable. `read --time` names the
startup stages.

Still missing: a `bench` step and a corpus flag, so interleaving two binaries
is done by hand. A corpus is never committed (the whitelist `.gitignore`
forbids it, and a renderer's corpus is other people's documents): point at an
out-of-tree directory. The one used here is the 28 PDFs in `~/Documents` —
papers, scans and typeset books covering Flate content, embedded CFF and
TrueType, JPEG images and heavy line art.

## The method

**Keep both binaries and interleave them.** Separate build-and-measure rounds
measure CPU frequency drift, not your change.

```powershell
zig build -Doptimize=ReleaseFast
Copy-Item zig-out\bin\fenrir.exe $env:TEMP\fenrir-before.exe
# ... make the change ...
zig build -Doptimize=ReleaseFast

$pdf = "$HOME\Documents\some-paper.pdf"
1..5 | ForEach-Object {
    (Measure-Command { & $env:TEMP\fenrir-before.exe raster $pdf --all --stats --time }).TotalMilliseconds
    (Measure-Command { & zig-out\bin\fenrir.exe       raster $pdf --all --stats --time }).TotalMilliseconds
}
```

Report the best of five, not the mean: the minimum is the run least disturbed
by the rest of the machine.

**The hash must be identical, not close.** Compare the `hash` `--time`
prints. For a per-page check, write PNGs with each binary (`-o before\page.png`)
and compare `Get-FileHash` sets. A change that moves a pixel is a rendering
change: it needs its own justification, images and commit.

**`--path both`** compares the stencil and analytic rasterisers inside one
build. It is not a substitute for the before-and-after hash, but it catches a
change that broke one path and not the other.

**On the GPU the proof is a shot.** `read F --path gpu --shot s.png` reads
the frame back from the device, and two runs of one binary write the same
bytes. Compare `Get-FileHash` of shots from both binaries, at the same page,
zoom and window size. A shader change that moves a pixel is a rendering
change, the same as on the CPU. See "The GPU path" for the timers.

**Leave `--jobs` at 1 when measuring the rasteriser.** Six threads turn a 2%
change into noise, and the columns become work done rather than time waited.
Use `--jobs` to measure `--jobs`, reading its `wall` line.

**Know what `raster --all` times.** Each page gets a fresh `DebugAllocator`
for `Glyphs` and `Images` (it catches cross-allocator frees on a corpus run,
at a cost that lands in every profile), and one page arena reused with
`reset(.retain_capacity)`. The reader runs the same code on a real heap.

For the interface, the workload is `fenrir read F --frames 1200 --vsync off`,
under the same rules.

## Where the time is

Measured on *Pretrained Transformers*, 26 pages at 96 dpi, ReleaseFast:

| column | share | |
|---|---|---|
| render | 90% | Gleipnir, on one core |
| canvas | 8% | allocating and clearing sixteen bytes a pixel |
| fonts | 1% | after the per-document face cache |
| interpret | < 1% | the whole of Gjöll |

Pages run in parallel under `--jobs`; nothing inside a page does, although
`tyr/raster.zig` notes that rows are independent. There is a little SIMD
(`allClear`, and `resolve`'s sixteen-byte sweep); `@shuffle`,
`@setFloatMode`, `@branchHint` and `@prefetch` appear nowhere.

Open hypotheses, by module:

**Gleipnir.**
- `Canvas.rasterTriangle` dominates: the fan triangles overlap, so its work
  is the summed area of the fan, not the area of the path.
- `stroke.disc` calls `@cos` and `@sin` per vertex for round joins and caps,
  up to 128 vertices each.
- `slug.rayAlongX`/`rayAlongY` gather through two indirections per curve per
  pixel, copy a 24-byte struct through `swapped()` to exchange axes, and
  recompute the `reach` the band was sorted by.
- The cubic flatteners (`gleipnir/path.zig`, `tyr/raster.zig`) divide by `n`
  per segment and evaluate the full Bernstein form where forward differencing
  would do.
- The framebuffer is four `f32` a pixel, so a page at 2× is a 31 MB working
  set and every full sweep is bandwidth-bound. This is deliberate: the file is
  meant to be the oracle the GPU is checked against. Nothing does the checking
  yet; see Tier 3 item 13 and "The GPU path".

**The JPEG decoder** (`gjoll/filter/jpeg.zig`), after the DC-only shortcut:
- `bit()` reads one bit at a time, branching on refill and `0xFF` stuffing;
- Huffman decoding walks code lengths a bit at a time;
- `idct` is the textbook separable double loop, about sixteen multiplies a
  pixel where AAN needs about five.

**Týr.**
- `drawLine` adds a constant `d * s` along a contiguous run in a scalar loop.
- `fill` runs a serial prefix sum per row.
- `truetype.zig`'s `simple()` declares three `max_points = 10_000` arrays: a
  90 KB stack frame per call, recursing up to five deep.
- `vanagandr/glyphs.zig` re-decodes the outline for every glyph occurrence.
  Read the graveyard before touching that.

**Gjöll.** Under 1% of the run, so these are memory and tidiness, not speed:
- `Scanner.array` allocates a fresh list for every `TJ` operand.
- `Interpreter.State` holds two `ColorSpace` values by value, and `q` copies
  the whole struct.
- Shadings reload on every reference, and a type-0 function re-inflates its
  samples each time.
- Every resource lookup (`selectFont`, `extGState`, `doXObject`,
  `colorSpace`, `patternPaint`) re-resolves its sub-dictionary.
- `xref.indexObjectStreams` parses each recovered object twice.

## The worklist

Ranked by payoff against risk. If a profile disagrees with an item, write that
in the graveyard and move on.

**Tier 0: the harness.** Half done: the timer and hash exist. `bench` and the
corpus flag do not; see "Added after review".

**Tier 1: unbounded or repeated work.** Done.
1. ~~Memoise `Document.streamData` and decode off the arena.~~ Landed, keyed
   on the `Stream`'s address, and `Interpreter.stream_cache` deleted. It
   halved the interpret column and left the total unchanged.
2. ~~Hoist `Glyphs` and `Images` to per-document.~~ The glyph half landed as
   `glyphs.Cache`. The image half is argued against: a decoded image is tens
   of megabytes.
3. ~~A DC-only JPEG IDCT.~~ Landed: **7% off an image-heavy document**,
   bit-exact.
4. ~~Cache the `DisplayList` per `(buffer, page)`.~~ Measured at 0.6% of a
   zoom and reverted; see the graveyard.

Left, and both are memory, not speed:
- **A `Document` that does not retain every page.** A 519-page scan peaks at
  3.5 GB, all of it the document arena. Bounding it changes the library's
  ownership rule, which makes it a design change.
- **Per-document decoded images**, but only behind a byte budget and an
  eviction policy.

**Tier 2: the pixel loops, bit-exact.** Done: **19% off a paper**, every hash
unchanged.
5. ~~Comptime-specialise `rasterTriangle` on `(pass, rule, samples)`.~~ The
   whole of the win.
6. ~~Hoist the edge functions and the clip row.~~ Written as
   `d = base - dy*x`, one fused multiply-add per pixel. A running total would
   accumulate drift that the margin would have to absorb.
7. ~~Vectorise `allClear` and `resolve`.~~ `tyr/raster.zig`'s span is still
   scalar.
8. ~~Hoist the fill colour's encode out of `blend`.~~ The flatteners' `1/n`
   remains.
9. ~~`disc`, `signedArea`, `pushClip`'s divide, TrueType's stack arrays.~~
   Dropped. None is per pixel, and the two changes of that kind that were made
   came to 1.9% together.

Two hazards stay live:
- **The top-left rule.** The cover quad is two triangles sharing a diagonal,
  and a sample on that diagonal must land in exactly one of them. Any change
  to the per-sample test must reproduce `edgeInside` exactly; `Edge.margin`
  exists because the bracket and the exact test can disagree in the last
  bits. Only the hash diff can say a change survived.
- **Index a clip row from the box's own origin** (`+ (x - x0)`). The first
  hoisted row underflowed on any clip not starting at x = 0. ReleaseFast
  wrapped it into the right answer and every hash matched; only a ReleaseSafe
  screenshot found it.

**Tier 3: structural, or changes output.**
10. A scratch buffer for `Scanner.array`; indirect `ColorSpace` in `State`; a
    shading cache; resource sub-dictionaries hoisted per content stream.
11. Pack `(reach, index)` into the slug bands, so the early exit needs no
    gather and the sort no comparator indirection. The shader walks the same
    two indirections (`rayAlongX` in `slug.glsl`), so this is one change for
    both. It moves data and not arithmetic, so the CPU hash must not move.
12. **Threads.** ~~Pages~~: `raster --all --jobs N`, **4.4× to 5.0× on six
    cores**, every hash unchanged. **Rows are still to do**, and they are what
    a person waiting on one page would feel. Splitting a page into bands moves
    the transform by whole pixels, and `a*x + b*y + (f - y0)` is not
    `(a*x + b*y + f) - y0` in floating point, so the hashes would move. Try
    splitting the *display list* by band instead: each thread keeps the
    unmodified transform and clips to its own rows. On the GPU path a zoom
    is a matrix, so rows help `raster`, `--path cpu`, and the pages the GPU
    path hands back to the CPU. They do not help a reader on the GPU.
13. **A narrower framebuffer.** Eight or four bytes a pixel would halve or
    quarter the bandwidth and change pixels. That makes it a rewrite, and it
    ends the file's role as the GPU's oracle. Propose it as a rendering change
    or not at all.

## Leave these alone

These are already right. Change them only when a profile names them.

- **The Vulkan frame loop.** Two frames in flight. Instance buffers are
  mapped once. No heap allocation per frame. One draw call per layer, and the
  quad comes from `gl_VertexIndex`. The clip is in the instance. Command
  pools are transient and reset. Viewport and scissor are dynamic, and
  `oldSwapchain` is passed. Render-finished semaphores are per swapchain
  image. There is no `vkDeviceWaitIdle` on the frame path.
  `PathRenderer.upload` is generation-gated, so a still reader uploads
  nothing. The stalls that remain are outside the steady state, and each says
  why it is safe. None of this was measured, and it covers only a reader
  that is still. A moving reader is flaws F2 and F3 below.
- **`Font.cidWidth`'s linear scan.** Measured: it beats anything cleverer
  until it does not. Re-measure it on a large CJK font before changing it.
- **`Scanner`'s one-byte dispatch and `Lexer`'s borrowed slices.** They are
  why content parsing is cheap. Do not add an allocation to them.
- **Gelgja.** Struct-of-arrays, with paths as ranges, and `paint.zig`
  allocates nothing. At most, reserve a capacity floor in `Builder.init` or
  reuse one `Builder` across pages.
- **Þviti's frame arena.** It resets with its capacity retained, keyless boxes
  live in it, and text shaping is cached by `(FontId, text)`.

## What must not break

- **The stencil is clean after every page.** `vanagandr/raster.zig` checks
  this on real documents.
- **The top-left rule** (Tier 2).
- **The clip box means what it says.** Without it, a scatter plot of 1,635
  two-point clips costs five gigabytes of memory traffic and three and a half
  seconds.
- `zig build test` is green. `-Dsqlite=false -Dlua=false` compiles and skips
  cleanly. A ReleaseSafe build and one cross-compile pass if the platform or
  the build changed.
- No new dependencies. A SIMD helper library is a dependency.
- Zig 0.16's std, checked against the installed source. The vector and
  `@branchHint` APIs are exactly what moves.
- Wayland is compile-verified only.

## The GPU path

Everything above measures `raster`, which never opens a device. The reader
has a second rasteriser. Its first measurements are in the ledger, under
"The GPU path, first measured". It works like this:
- `replay.record` walks the same display list into a `Scene`: outlines as
  quadratics, instances that place them, and a clip chain;
- `PathRenderer` puts the scene in eight storage buffers;
- `slug.frag` works out each pixel's coverage from the curves.

A glyph is recorded once per page, in em units, and each occurrence of it is
an 80-byte instance. A zoom is a matrix.

**Why the reader does not use it.** `read` picks `.cpu` whenever the build
has both rasterisers (`backend = if (have_gpu and !have_cpu) .gpu else .cpu`),
and `-Dpath=both` is the default. So the GPU path runs only under
`--path gpu`. Two other places look like GPU text and are not:
- `raster --path slug` is the shader's CPU model and never touches a device;
- the interface's text is Týr's atlas, which is right for text at fixed sizes.

The default is right today, for the reasons in F1: at 800% the GPU path
draws strokes and clips as polygons, and hairlines eight pixels wide. It also
has five of the sixteen blend modes. The intent is to make `.gpu` the default
once G1 is done, with a per-page fallback: a page whose recording could not be
drawn exactly is rasterised on the CPU and shown as a texture. The reader
already holds both kinds of result.

### What is wrong with it

These were found by reading, so each is a hypothesis until the G0 timers
confirm it. F1 and F4 are about correctness; the others are about cost.

- **F1. Strokes, clips and hairlines are baked at 72 dpi.** `recordPage`
  records at zoom 1.0, and the flattener's tolerance is a tenth of a device
  pixel *at that zoom*.
  - Fills keep their curves (`slug.fromPath`). Strokes (`strokePath`) and
    clips (`pushClip`) are flattened first, so at 800% the polygon strays by
    0.8 px. Clips can take `slug.fromPath` the way fills do.
  - A hairline resolves to one device pixel (§8.4.3.2) at record time, so it
    is eight pixels wide at 800%.
- **F2. Scrolling re-places every instance.** `placeVisible` composes a
  matrix and a scissor for every instance of every visible page, and `upload`
  sends all of them, eighty bytes each, whenever the view moves. A page of
  prose is about four thousand instances, so a scroll costs a few hundred
  kilobytes a frame and a loop over them on the frame thread. The outlines
  were recorded in page space so that a move would cost one matrix; it costs
  one per instance.
- **F3. A page past the cache rebuilds all of them.** `Recorded` holds
  twelve pages in one append-only store.
  - The thirteenth page evicts one, and `rebuild` merges the eleven survivors
    again.
  - Then every binding, texels included, is uploaded again, once for each
    frame in flight.
  - The buffers are host-visible and only *prefer* device-local. On a card
    without resizable BAR (this one), that is a 256 MB heap. When it is full,
    `allocateMemory` fails instead of falling back to system memory.
  - **Confirmed by `--bench`.** On this card the heap reports 214 MiB.
    *Nanite_2021* under `--path gpu --bench scroll` or `flip` asks for a
    128 MiB texel buffer for the second frame in flight, beside 68 MiB of path
    buffers already there, including the first frame's 64 MiB copy of the same
    texels. The allocation fails with `OutOfDeviceMemory`, and the reader
    exits with status 1 and no message: `main` exits quietly on any error that
    nothing reported. It happened in eight of ten runs; the other two were cut
    short before reaching that page.
- **F4. The texel budget is per page.** `max_texels` is 128 MiB, the smallest
  `maxStorageBufferRange` Vulkan promises. `Scene.drawImage` enforces it while
  a page records, but `Scene.merge` does not. Twelve pages of a scan can
  exceed it on a device that offers only the minimum.
- **F5. Per-fragment work that belongs on the host.** `slug.frag` inverts the
  instance's matrix and derives pixels-per-unit for every fragment, then again
  for every clip node it walks. Both are constants of the placement.
  `Canvas.fillSlug` inverts once per fill, so moving this work would also
  bring the shader closer to its model.
- **F6. Two gathers per curve.** A fragment reads a band, then an index, then
  the curve, and recomputes the reach to decide the early exit. This is Tier 3
  item 11, on both sides.
- **F7. Overlapping stroke pieces are counted twice at an edge.** Found by the
  stencil-against-slug test in `replay.zig`, not by reading. The stroker
  unions its pieces under nonzero. Where two of them have an edge in the same
  pixel, each ray adds both partial crossings, so the pixel comes out covered
  where it is half covered. A 4 pt round-joined zigzag gets 1.9% more ink than
  stencil-and-cover at 72 dpi, and 0.6% more at 3×. A stroker that emits one
  outline rather than a union of pieces would fix it, and so would evaluating
  strokes as distance to the centreline.

### How to measure it

The same rules apply, with a different oracle.
- **Time on the device.** Write timestamps around the frame and around the
  path draws, and read them back after the frame's own fence, so reading never
  stalls. `read --time` reports:
  - GPU frame and path milliseconds, as the best, median and 95th percentile;
  - the CPU's frame time;
  - the time spent in `placeVisible`;
  - bytes uploaded per frame.
- **A scripted workload.** `read F --bench scroll|zoom|flip --vsync off`,
  which implies `--time`.
  - `scroll` moves a twentieth of a page each frame, to the end.
  - `zoom` goes from 50% to `View.max_zoom` and back, twice, on one page, by
    5% a step. The limit is 8 pixels a point: eight times the scale a page is
    recorded at, which the reader's status line calls 600% at 96 dpi.
  - `flip` shows every page in turn, which exercises F3.

  Each step waits for the pages it brings into view, and a page is drawn for
  one frame after it arrives. So frame cost and page arrival are separate
  numbers: `frame` counts only frames with nothing missing, and `arrival`
  times a step to its last page. The device timers count every frame. Run it
  under both `--path cpu` and `--path gpu`: that is how a re-render is
  compared with a matrix.
- **Where the buffers live.** `--time` also prints the path buffers' memory
  type and the size of its heap.
- **Output.** Take a GPU shot hash before and after (see "The method").
  `scene.modelFrame` runs the fragment shader over a whole recorded frame on
  the CPU, so a `Scene` can be checked against `replay.render` without a
  device.

RenderDoc stays the tool for finding *why* a frame is slow. These say
*whether* it is.

### The GPU worklist

**G0: the harness.** Built: the timers, the workloads and the memory report,
and the tests that hold the scene format still (merge and eviction,
placement, the clip chain, and the model against `render`). The baseline is
in the ledger.

**G1: correct before default.** Each item changes GPU pixels and needs shots.
- Clips through `slug.fromPath` rather than flattened.
- Strokes flattened at a tolerance that holds to `View.max_zoom`, or a
  stroker that emits quadratics. Either way, measure how much the store grows.
- Hairlines resolved in the shader. The width is the device's, and cannot be
  decided at record time.
- A texel budget for the merged scene, and a fallback when the preferred
  memory heap is full.
- Then `.gpu` by default. A page is drawn on the CPU when its recording counts
  `blended`, `images_dropped` or `clips_too_deep`.

**G2: on change, not per frame.**
- Instances uploaded once with their page, in page space. A frame sends one
  placement per visible page and window, as a push constant per draw, so a
  scroll uploads nothing.
- One region of the store per cache slot, addressed by base offsets rather
  than renumbered. An eviction then overwrites one region and merges nothing.
- Device-local buffers written through a staging copy, with one copy of a
  page's outlines rather than one per frame in flight. They do not change
  while a frame reads them.

**G3: per fragment.** Measure each item with the device timer on a page of
prose, a page of line art, and the scatter plot of 1,635 clips.
- Inverse and pixels-per-unit computed on the host (F5).
- The clip chain evaluated before the path, so a fragment that is clipped
  away never walks the glyph's bands.
- `(reach, index)` in the bands (F6).
- An instance whose box is large and mostly empty, such as a long diagonal
  stroke, split into tiles that have curves.
- Images as sampled textures with mipmaps, rather than sixteen nearest
  fetches from a buffer. This changes pixels.

**G4: startup.** A `VkPipelineCache` kept beside the database, measured
against the `renderer` and `paths` stages.

Budgets. The baseline behind them is in the ledger under "The GPU path, first
measured".
- **Scroll.** A scroll uploads no instances: 542 KiB of path data a frame on
  *Pretrained Transformers* today, and under 1 KiB after. A scroll frame costs
  no more than the CPU path's, which is 0.26 ms today, against 0.46.
- **Flip.** A flip past the cache moves one page's bytes, not twelve. Averaged
  over a flip of the paper that is 377 KiB a frame today. A page's arrival
  stays under the 4.6 ms median it has now.
- **Nothing fails.** Every workload runs on *Nanite_2021* and the scan. Two
  fail today.
- **The path draw.** On a page of prose it stays under 2% of a 60 Hz frame
  (0.33 ms) at the 95th percentile. It is 0.20 ms on `scroll` and 0.28 on
  `zoom` today.

## The ledger

Windows 11, GTX 1650 SUPER, ReleaseFast. Both binaries are kept and
interleaved, best of five or six, and every claim is checked with the `--time`
hash across all 28 documents.

**Where the time went.** *Pretrained Transformers*: 2,250 ms, of which render
2,030, canvas 190, fonts 25 and interpret 16. The `fonts` lap first read
219 ms because it also held the canvas allocation. Split a lap before
believing its label.

**Face construction per document** (`glyphs.Cache`). Fonts fell from
**25.3 ms to 6.2 ms**, and the total moved from 2,256 to 2,250 ms, which is
noise. It was kept for the reader, where it is latency the eye sees. It is
**not** a throughput win.

**Startup: 896 ms to 709 ms.** Same work, different order. The device took
362 ms, the swapchain 353 and the first page 223. Starting the page thread as
soon as the window exists puts page one on screen with the window. This only
applies when the backend is already `.cpu`; the call site says why.

**Tier 1.** The documents: *Pretrained Transformers* (26 pages, text),
*Nanite_2021* (155 pages, 333 images), *kolmbook-eng-scan* (519 pages, a
scan). Both orderings were run.

- **The canvas was on the CLI's arena, which never freed.** The scan peaked at
  **8,296 MB**. A page arena reused with `retain_capacity` brought that to
  **3,476 MB** and the canvas column from 3,160–4,261 ms to 2,148–2,276 ms.
  Two wrong answers were measured first, and each was **2.5% slower**:
  - a `DebugAllocator` for the page, whose cost landed in render;
  - a fresh arena per page, which faults cold memory every page.
- **`streamData` memoised:** interpret on the scan fell from 760–871 ms to
  343–375 ms. Peak RSS was 3,474 MB against 3,476 MB, so memory did not move.
  It was kept for the halved column and the deleted workaround.
- **The DC-only IDCT:** *Nanite_2021* went from **41,131 to 38,217 ms (7.1%)**
  and won all four interleaved pairs. It is bit-exact because it is the same
  two multiplies in the same order.

**Tier 2: 19.0% on the total, 22.6% on render**, winning all five pairs, with
hash `bf68db5063ccf734` before and after.

| | best of five | render |
|---|---|---|
| before | 2,603.93 ms | 2,440 ms |
| after | 2,109.34 ms | 1,889 ms |

- *One triangle raster per pass, rule and sample count*: **20.4%**, the
  whole of it.
- *Encode the fill colour once, skip empty cover rows*: **1.9%**. Nobody
  should go looking for another one like it.

What paid was deleting two branches and a runtime slice from a loop that runs
eight times per pixel per triangle, so the compiler could unroll it. Here,
giving the optimiser a loop whose shape it knows is what pays.

**Pages on threads** (`--jobs`), wall clock, best of three per ordering:

| | 1 thread | 6 threads | | peak RSS 1 → 6 |
|---|---|---|---|---|
| *Pretrained Transformers* | 1,829 ms | 415 ms | **4.4×** | |
| *Nanite_2021* | 29,169 ms | 5,737 ms | **5.0×** | 105 → 332 MB |
| *kolmbook-eng-scan* | 35,345 ms | 6,999 ms | **4.9×** | 3,443 → 3,571 MB |

All 28 hashes agree at one and six threads, and the PNGs are byte-identical.
That holds by construction: one thread still renders each page, through the
same code in the same order. Each thread opens its own `Document` over the
same bytes (`Document.openBorrowed`). A shared document behind a mutex would
have serialised image decoding, which happens during the render.

**Stencil against slug, both on the CPU.** *Pretrained Transformers*, one
binary, the two `--path` values interleaved, best of five:

| | total | render | hash |
|---|---|---|---|
| `--path stencil` | 1,769.03 ms | 1,592.85 ms | `bf68db5063ccf734` |
| `--path slug` | 981.54 ms | 804.74 ms | `41213873b2b6f905` |

The analytic model renders this paper in **half the time** of eight-sample
stencil-and-cover. Each hash held across all five runs. The reader's CPU path
draws with stencil. See item 8 under "Added after review".

**The GPU path, first measured.** The setup:
- **Binary:** ReleaseFast at `b7b122b`, running
  `read F --path P --bench W --vsync off --clean` in a 1000×900 window.
- **Rounds:** five, interleaved. Each round runs every document, workload and
  backend once.
- **Numbers:** each is the best of the five, meaning the lowest median and the
  lowest 95th percentile, given as median / p95 in milliseconds.
- **Columns:**
  - `frame` is the time between two frames with nothing missing;
  - `gpu` and `paths` are the device's own timestamps, over every frame;
  - `arrival` runs from a step to its last page arriving;
  - `upload` is KiB of path data a frame, averaged over the run.

Six runs ended before their workload did. Five had their window closed
partway through, and one stalled until the 20-minute timeout. They were run
again, and every cell below has five complete runs.

On the GPU:

| | | frame | gpu | paths | place | arrival | upload |
|---|---|---|---|---|---|---|---|
| *Pretrained Transformers* | scroll | 0.46 / 1.39 | 0.25 / 0.33 | 0.12 / 0.20 | 0.04 | 1.1 / 7.4 | 542 |
| | zoom | 0.57 / 0.93 | 0.30 / 0.42 | 0.17 / 0.28 | 0.03 | first page only | 197 |
| | flip | 0.74 / 4.06 | 0.13 / 0.25 | 0 / 0.12 | 0.01 | 4.6 / 7.7 | 377 |
| *Nanite_2021* | scroll | fails | | | | | |
| | zoom | 0.22 / 0.62 | 0.13 / 0.37 | 0 / 0.24 | 0.01 | first page only | 32 |
| | flip | fails | | | | | |
| *kolmbook-eng-scan* | scroll | 2.29 / 3.15 | 0.32 / 0.37 | 0.16 / 0.21 | 0.19 | 1.8 / 4.4 | 537 |
| | zoom | 0.50 / 0.82 | 0.17 / 0.18 | 0.01 / 0.02 | 0.00 | first page only | 13 |
| | flip | 1.81 / 2.92 | 0.13 / 0.27 | 0 / 0.14 | 0.06 | 8.6 / 15.0 | 221 |

On the CPU, the same runs:

| | | frame | arrival |
|---|---|---|---|
| *Pretrained Transformers* | scroll | 0.26 / 0.92 | 98.5 / 127.3 |
| | zoom | 2.45 / 14.64 | 424 / 1,959 |
| | flip | 0.80 / 1.87 | 105.1 / 131.7 |
| *Nanite_2021* | scroll | 0.29 / 0.88 | 191.5 / 563.3 |
| | zoom | 0.22 / 3.30 | 960 / 3,958 |
| | flip | 0.24 / 0.72 | 187.3 / 584.6 |
| *kolmbook-eng-scan* | scroll | 1.88 / 2.32 | 94.7 / 197.7 |
| | zoom | 2.07 / 11.15 | 87.4 / 415.9 |
| | flip | 1.16 / 2.16 | 111.3 / 221.6 |

What it says:
- **Zoom is where the GPU path earns its place.** It never waits for a page:
  each step is a matrix, and a frame costs 0.2–0.6 ms. The CPU path
  rasterises the page again at every step. That is a median of 424 ms on the
  paper and 960 ms on *Nanite_2021*, with p95 of 2.0 and 4.0 s. The paper's
  205-step zoom takes 105 s of wall time on the CPU and about one on the GPU.
- **Scrolling costs more on the GPU path than on the CPU path.** On the
  paper a frame is 0.46 ms against 0.26; on the scan it is 2.29 against 1.88.
  That is F2, measured: every frame re-places every instance and uploads
  542 KiB of path data. The device's own share is small. The paths take
  0.12 ms, under 1% of a 60 Hz frame.
- **A page arrives 13 to 23 times sooner.** Recording is the walk without
  the rasteriser. A flip takes 4.6 ms against 105 on the paper, and 8.6
  against 111 on the scan. That includes F3's rebuild once the cache is full.
- **Two workloads fail.** *Nanite_2021* runs out of the BAR heap under
  `scroll` and `flip`; see F3.
- **A long document costs the CPU on every frame, on both backends.** A
  scroll frame on the scan's 519 pages takes 1.9–2.3 ms, against 0.26–0.46
  on the paper's 26, and the device is busy for 0.32 ms of it. A lead, unmeasured:
  `View.visiblePages` calls `pageTop(i)` for each page before the viewport,
  and `pageTop` sums every page before `i`. That is quadratic in the page
  number.

The GPU shot of page 3 at 150% (`--page 3 --zoom 1.5 --shot`) is the same
twice in a row for each document:

| | sha256 |
|---|---|
| *Pretrained Transformers* | `cda52ad5bb7b3c0e` |
| *Nanite_2021* | `78a5a3595f146e79` |
| *kolmbook-eng-scan* | `12a3c2faf54519cc` |

## The graveyard

Measured and lost. Append yours, with the number.

- **A glyph outline cache.** 95% hit rate, **6% slower**; decoding was 1% of
  the run. It argues against caching *outlines*, not against hoisting *face
  construction*.
- **A `DisplayList` cache per `(buffer, page)`.** Interpreting a page takes
  0.33–0.66 ms against 75–250 ms to render it, so the cache is worth **0.6%**
  of a zoom. A zoom waits on Gleipnir.
- **A `DebugAllocator` per page, and a fresh arena per page.** Each was 2.5%
  slower than the arena that never freed. The answer was to keep the arena and
  change its lifetime.

## Added after review

Tasks the ledger now argues for, in order. Each is a hypothesis with its
measurement attached.

1. **A function-level profile after Tier 2.** The ledger has four columns and
   no functions, and Tier 2 changed the shape of the hottest loop. Sample
   `raster --all --stats` on ReleaseSafe with Superluminal or WPR, and record
   the top ten functions with their shares here. Tier 3 waits on it.
2. **Finish Tier 0.** Add `zig build bench -Dcorpus=DIR`. It builds
   ReleaseFast, keeps the previous binary as `fenrir-prev`, runs both
   interleaved N times over the corpus, and prints best-of-N per document and
   whether each hash matched. This replaces the hand-run loop and makes
   forgetting to interleave impossible.
3. **Latency a reader feels.** `read --time` stops at the first page. Add per
   event timings: a zoom, from the key to the sharp page, and a scroll onto a
   page not yet rasterised. Row threading (item 12) is justified by exactly
   this and has no number to beat. `read --bench` (G0) is where these come
   from, on both paths.
4. **Split the canvas lap** into allocate, fault and clear. It is 8% of a run.
   After the arena fix, faulting should be gone. If clearing dominates, a
   tile-level lazy clear skips a page's untouched margins and stays bit-exact,
   unlike item 13.
5. **Find what the swapchain's 353 ms is.** That is long for a swapchain.
   Pipeline creation is not inside it. The rect pipelines are built in the
   `renderer` stage and the five path pipelines in `paths`, and both are
   marked separately by `read --time`. So a `VkPipelineCache` is measured
   against those two stages (G4). What the swapchain's own time is remains
   open. If it is all driver time, record that and stop.
6. **The JPEG decoder's other three**, in this order, each measured alone on
   *Nanite_2021*: a lookup table for Huffman codes up to nine bits, a
   word-refilled bit reader, then AAN.
7. **Budgets for the planned features** (`ui.md` phases 10–17), set before
   they are built:
   - `fenrir diff` compares display-list hashes first, so identical pages are
     never rasterised: *Nanite* against itself drew nothing, in 124 ms. The
     early stop at the tolerance was measured out rather than built:
     comparing a pair is 1–2% of drawing it (`ui.md`, phase 10).
   - A canvas of 1,000 comments docked beside a page must keep
     `read --frames 1200` within noise of the reader without it.
   - Anything drawn from a page replays the recorded scene and is never
     re-interpreted.
8. **The CPU reader on slug.** The analytic rasteriser renders a paper in
   half the time of the stencil one (see the ledger), and it is also what the
   GPU draws, so a page would look the same on either path. It changes every
   antialiased edge, which makes it a rendering change to argue with images,
   not an optimisation. Measure a scan and *Nanite_2021* before arguing it:
   one paper is not a corpus. Clips are the open question, since `fillSlug`
   still reads the stencil's clip mask.

## Finishing

Run `zig build test`, a ReleaseSafe build, and a cross-compile if the
platform or the build changed. Then commit as `CLAUDE.md` says:
- one feature per commit, about 300 to 700 lines;
- a changelog line under 72 characters;
- at most three a day, at plausible `+0600` times.

The message carries no benchmark, but record the number here: what was
measured, on which file, best of how many, and that the hashes matched. An
optimisation nobody can reproduce is indistinguishable from a refactor.
