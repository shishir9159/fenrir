# fenrir

A PDF reader written from scratch in Zig and drawn with Vulkan. No parsing
library, no UI toolkit, no font library, no GTK, no SDL. The only C is SQLite
and Lua, compiled from pinned source by `build.zig`, and either can be left
out.

## Status

`fenrir read paper.pdf` opens a document in a window: continuous scrolling,
zoom and fits, Vim-style windows and tabpages, highlights, notes and ink that
survive reopening, search, a command palette, and plugins. `fenrir diff`
opens two revisions side by side at their first change, as diff-pdf does.
`fenrir raster` writes the same page to a PNG with no device at all. Across a
400-document corpus every glyph on every first page is accounted for: drawn,
blank, or an invisible OCR layer over a scan.

- **Gjöll** reads the whole container and interprets all 73 content-stream
  operators into a display list, including colour spaces, functions, form
  XObjects, inline images, patterns, Type 3 glyphs and annotation appearance
  streams.
- **Gleipnir** draws paths two ways. Stencil-then-cover runs on the CPU and
  models a GPU stencil buffer down to its eight-bit wraparound. The analytic
  rasteriser computes coverage from the curves themselves, after Eric
  Lengyel's [Slug](https://github.com/EricLengyel/Slug), on the CPU or the
  GPU. On the GPU a page is a few draw calls and a zoom is a matrix, not a
  re-render. Rects are a signed distance field: one instance format, one draw
  call a frame.
- **Týr** parses `glyf`, CFF/Type 2 and Type 1 itself; FreeType and
  stb_truetype stay optional. A glyph's outline goes to the device once, in em
  units, and each occurrence is a matrix naming it: one page of a paper is
  3,805 glyphs from 5,683 curves rather than 121,651.
- **Images** decode through Flate and the byte filters, and `/DCTDecode`
  through a baseline JPEG decoder written for this. JPEG 2000, CCITT and JBIG2
  are counted and skipped.
- **Lyngvi** opens a window on Win32 or Wayland and loads Vulkan at run time
  through hand-written bindings: no SDK, no headers, and no C linked by
  default.
- **Mímir** keeps, per document, the place (a page and how far down it in
  points, so another zoom lands on the same line) and the marks, and keeps the
  reader's settings. `-Dsqlite=false` builds a reader that forgets.
- **Hliðskjálf** follows Vim: a buffer per document, windows as views onto
  one, splits and tabpages. The cursor regroups glyphs into lines by position,
  so `j` walks a two-column paper the way you read it. Marks belong to the
  buffer, so every window on a document shows the same ones.
- **Galdr** is Neovim's plugin model (`init.lua`, `plugins/`, a `fenrir`
  table) in a sandbox with no files, no processes, and limits on memory and
  time.

## Building

Zig 0.17.0 and nothing else: no CMake, pkg-config, Python, system SQLite or
Lua, Vulkan SDK, or C compiler beyond the one inside Zig. A Vulkan driver to
run the reader, and one network fetch on the first build for the two libraries
this project links on purpose.

```
git clone <this repository> fenrir && cd fenrir
zig build                 # zig-out/bin/fenrir
zig build test            # the whole suite
zig-out/bin/fenrir read paper.pdf
```

Every option, how SQLite and Lua are pinned by hash, where the SPIR-V comes
from, how to cross-compile and what to do when the build fails are in
`build.md`.

## The documents

[`myths.md`](myths.md) is the module map: why each one is named for a piece of
the Fenrir myth, which way the dependencies run, and where the files are. It
and this file are the two kept in the repository.

The rest are working notes kept beside the source and not committed:
`build.md` the build and its profiles, `usage.md` the reader and the CLI,
`plugins.md` the Lua surface, `design.md` the decisions that are load-bearing
and the gaps that remain, `OPTIMIZING.md` the performance ledger and its
method, `ui.md` the interface plan.

## Profiling

`fenrir raster <file> --all --stats` is the standard CPU workload, and
`--time` hashes every page's pixels as it goes, so a change meant to be free
can be shown to have been. The harness, the ledger and the worklist are in
`OPTIMIZING.md`.