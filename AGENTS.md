# fenrir

A PDF reader and editor written from scratch in **Zig 0.16.0** and **pure
Vulkan**. No parsing library, no UI toolkit, no font library, no shader
compiler at run time. The only two C dependencies are SQLite and Lua, both
compiled from pinned, checksummed source by `build.zig`.

`CLAUDE.md` is a copy of this file. Edit one and copy it to the other.

## Modules

Named from the Fenrir myth. Dependencies run strictly one way, downward.

| Module | `src/` | What it is |
|---|---|---|
| Gjöll | `gjoll/` | PDF parsing: lexer, objects, xref, filters, content streams |
| Gelgja | `gelgja/` | The display list a page interprets into |
| Gleipnir | `gleipnir/` | Rasterising: paths, stroking, the CPU canvas, slug coverage |
| Týr | `tyr/` | Fonts: TrueType, CFF, Type 1 outlines |
| Þviti | `thviti/` | UI widgets and input |
| Lyngvi | `lyngvi/` | Platform and Vulkan: windows, device, swapchain, renderers |
| Mímir | `mimir/` | SQLite storage: recent files, places, settings, highlights |
| Hliðskjálf | `hlidskjalf/` | Buffers, views, the split tree, marks, the modal keymap |
| Galdr | `galdr/` | Sandboxed Lua 5.4 plugins |
| Vánagandr | `vanagandr/` | The CLI: one file per command |

Nothing below `Document` knows documents exist. Nothing at or below `Document`
knows what a page is.

## Performance is the first priority

This is a renderer. A slow correct answer is a bug. Treat throughput and
frame time as part of the contract, not as a later pass.

**Measure first, always.** Do not optimise from reading the code. Profile, find
where the time is, then change that. Guesses lose: an outline cache with a 95%
hit rate once made this program 6% *slower*, because decoding glyphs was 1% of
the run.

**Benchmark honestly.**
- Build both binaries, keep them, and run them *interleaved* in the same
  session. Comparing across separate build-and-measure rounds measures CPU
  frequency drift.
- Report best-of-N, N ≥ 5.
- `fenrir raster <file> --all --stats` is the standard CPU workload.

**Prove the output did not change.** Render every page before and after and
compare file hashes. An optimisation that alters a pixel is a rewrite and needs
saying so.

**The rules that hold without measuring:**
- No allocation in a per-frame, per-page or per-glyph path. Hold the buffer on
  the struct and `clearRetainingCapacity`.
- No work per sample that can be done per pixel; none per pixel that can be
  done per triangle; none per frame that can be done on change.
- Bracket and reject early in the inner loops rather than testing every case.
- Cache only what a profile says is expensive.

## Build and test

```
zig build                  # debug binary in zig-out/bin
zig build test             # the whole suite; must be green before committing
zig build -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-linux-gnu    # cross-compile check
```

Options that matter: `-Dsqlite=false` and `-Dlua=false` (both default true; the
build must still compile and its tests skip cleanly), `-Dshaders=glsl|slang|spirv`
(`spirv` uses the committed modules and needs no compiler).

Before finishing any change: `zig build test`, plus a ReleaseSafe build and one
cross-compile if the change touches the platform layer or the build.

## Constraints

- **No new dependencies.** Not for parsing, UI, fonts, images or maths.
- Zig 0.16 std only. It moves; check the installed std source rather than
  recalling an older API.
- Comments say *why*, not what. Match the density and voice of the file you are
  editing.
- Wayland is compile-verified only — there is no Linux on this machine. Never
  claim it was run.

## Commits

- Commit uncommitted work. **One feature per commit.**
- **At most 3 commits a day**, each with its own timestamp.
- **Under ~300 lines** per commit.
- Message **under 72 characters**, a changelog line: `added sqlite support`,
  `extended the keymap with visual mode`.
- **No fluff or filler. No AI attribution** — no `Co-Authored-By`, no
  "Generated with Claude Code". No context the diff already shows.
- Timestamps must be plausible: the gap between two commits is at least as long
  as a human would need to write the code in between. The repository uses
  `+0600`.

```
D="2026-09-16T19:30:48+06:00"
git add -- <files for this one feature>
GIT_AUTHOR_DATE="$D" GIT_COMMITTER_DATE="$D" git commit --date "$D" -m "added sqlite support"
```

`.gitignore` whitelists `*.md`, so `AGENTS.md` and `CLAUDE.md` are tracked.
Never add them to `.gitignore`.
