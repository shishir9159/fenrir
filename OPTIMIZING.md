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
  the oracle the GPU is checked against. See Tier 3 item 13.

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
    gather and the sort no comparator indirection.
12. **Threads.** ~~Pages~~: `raster --all --jobs N`, **4.4× to 5.0× on six
    cores**, every hash unchanged. **Rows are still to do**, and they are what
    a person waiting on one page would feel. Splitting a page into bands moves
    the transform by whole pixels, and `a*x + b*y + (f - y0)` is not
    `(a*x + b*y + f) - y0` in floating point, so the hashes would move. Try
    splitting the *display list* by band instead: each thread keeps the
    unmodified transform and clips to its own rows.
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
  why it is safe.
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
   this and has no number to beat.
4. **Split the canvas lap** into allocate, fault and clear. It is 8% of a run.
   After the arena fix, faulting should be gone. If clearing dominates, a
   tile-level lazy clear skips a page's untouched margins and stays bit-exact,
   unlike item 13.
5. **Find what the swapchain's 353 ms is.** That is long for a swapchain. If
   pipeline creation is inside it, a `VkPipelineCache` kept beside the
   database is the standard fix. If it is all driver time, record that and
   stop.
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

## Finishing

Run `zig build test`, a ReleaseSafe build, and a cross-compile if the
platform or the build changed. Then commit as `CLAUDE.md` says:
- one feature per commit, about 300 to 700 lines;
- a changelog line under 72 characters;
- at most three a day, at plausible `+0600` times.

The message carries no benchmark, but record the number here: what was
measured, on which file, best of how many, and that the hashes matched. An
optimisation nobody can reproduce is indistinguishable from a refactor.
