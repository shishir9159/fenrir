# fenrir

A PDF reader written from scratch in Zig and drawn with Vulkan. No parsing
library, no UI toolkit, no font library, no GTK, no SDL. The only C is SQLite
and Lua, compiled from pinned source by `build.zig`, and either can be left
out.

## Status

`fenrir read paper.pdf` opens a document in a window: continuous scrolling,
zoom and fits, Vim-style windows and tabpages, marks that survive reopening,
search, a command palette, and plugins. `fenrir diff` opens two revisions side
by side at their first change. `fenrir raster` writes a page to a PNG with no
device at all. What each module does is in [`docs/myths.md`](docs/myths.md).

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

[`docs/myths.md`](docs/myths.md) is the module map: why each one is named for a
piece of the Fenrir myth, which way the dependencies run, what each does, and
where the files are. It, [`docs/CONTRIBUTING_GUIDE.md`](docs/CONTRIBUTING_GUIDE.md)
and this file are the three kept in the repository.

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