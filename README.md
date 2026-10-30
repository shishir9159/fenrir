[Jimmy Lefevre – How to make a text box: A crash course in Unicode and OpenType – BSC 2026 - Better Software Conference](https://www.youtube.com/watch?v=7Tr0ty9-yeQ)
https://github.com/btzy/nativefiledialog-extended

# fenrir

A PDF reader written from scratch in Zig and drawn with Vulkan. No parsing
library, no UI toolkit, no font library, no GTK, no SDL. The only C is SQLite
and Lua, compiled from pinned source by `build.zig`, and either can be left
out.

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

The interface plan is [`ui.md`](ui.md); performance work is
[`OPTIMIZING.md`](OPTIMIZING.md).

## Building

| Needed | For | |
|---|---|---|
| **Zig 0.16.0** | everything | The only hard requirement. `winget install zig.zig` on Windows. `zig version` must print `0.16.0`; the standard library changes between releases. |
| **Network, once** | SQLite and Lua | Two archives (2.9 MB and 0.4 MB) fetched on the first build and never again. Not needed for one you turn off, or if you fetch by hand. |
| A Vulkan driver | `read`, `view` | Not for building. Any current GPU driver ships the loader. |
| A shader compiler | changing a shader | Optional; the SPIR-V is committed. See *Shaders*. |
| libwayland-client, libxkbcommon | the window on Linux | Opened at run time, not linked. |

Nothing else: no CMake, pkg-config, Python, system SQLite or Lua, Vulkan SDK,
or C compiler beyond the one inside Zig.

```
git clone <this repository> fenrir && cd fenrir
zig build                 # zig-out/bin/fenrir; fetches SQLite and Lua the first time
zig build test            # the whole suite
zig-out/bin/fenrir read paper.pdf
zig build run -- info paper.pdf    # build and run in one step
```

`zig build`, in order:

1. Resolves the dependencies that are turned on from `build.zig.zon`. A
   package already in Zig's global cache is used as is; otherwise it is
   downloaded, unpacked, hashed, and **refused unless the hash matches the
   pin**. A tampered, truncated or substituted archive fails before anything
   compiles.
2. Picks where the SPIR-V comes from (`-Dshaders`).
3. Compiles SQLite and Lua into two static libraries with Zig's C compiler.
4. Compiles fenrir (`src/root.zig` and `src/main.zig`) with the build options
   baked in, and links SQLite, Lua, libc where needed, and `user32` on
   Windows.
5. Installs `zig-out/bin/fenrir` (and `fenrir.pdb` on Windows).

`.zig-cache/` and `zig-out/` are ignored by git and safe to delete. SQLite and
Lua compile once per optimisation mode and target.

### Options

| Option | Default | |
|---|---|---|
| `-Doptimize=Debug\|ReleaseSafe\|ReleaseFast\|ReleaseSmall` | `Debug` | Read documents with `ReleaseSafe`: fast, and it still stops on a bad index instead of drawing garbage. `Debug` also checks every allocation for leaks and double frees on exit. |
| `-Dsqlite=true\|false` | `true` | Mímir's database. |
| `-Dlua=true\|false` | `true` | Galdr's Lua, and with it plugins. |
| `-Dpath=cpu\|gpu\|both` | `both` | Which path rasteriser the window may use. |
| `-Dshaders=auto\|glsl\|slang\|spirv` | `auto` | Where the SPIR-V comes from. |
| `-Dglsl-compiler=auto\|glslc\|glslang` | `auto` | Which compiler `-Dshaders=glsl` runs. |
| `-Dslangc=PATH` | on `PATH` | Where `slangc` is. |
| `-Dfreetype`, `-Dstb-truetype`, `-Dharfbuzz` | off | Optional font backends. |
| `-Dtarget=TRIPLE` | this machine | Cross-compile. |

```
zig build                 build and install zig-out/bin/fenrir
zig build test            every test in the library and the CLI
zig build run -- ARGS     build, then run fenrir with ARGS
zig build spirv           regenerate src/gleipnir/shader/spirv/ from GLSL or Slang
```

`zig build --help` lists every option; `--summary all` after any step shows
what was built, what was cached, and the test counts.

### SQLite and Lua

The two libraries linked on purpose. Each is pinned in `build.zig.zon` by the
hash of its **unpacked contents** (the URL says where to look, the hash says
what is acceptable to find there), is `lazy` so a build that turns it off
never fetches it, and is cached once per machine (`zig env` prints
`global_cache_dir`; packages live under `p/`).

```zig
.sqlite = .{
    .url = "https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip",
    .hash = "N-V-__8AAGVtrgCcOcmjrOJnagmnRyMrcKaOo09KbU-vu8w8",
    .lazy = true,
},
.lua = .{
    .url = "https://www.lua.org/ftp/lua-5.4.9.tar.gz",
    .hash = "N-V-__8AAEQ_FAAnte7Oq7KSLG9FZh_9mjvQimoekgYqkKSK",
    .lazy = true,
},
```

| | SQLite 3.53.4 | Lua 5.4.9 |
|---|---|---|
| Used by | Mímir only | Galdr only |
| Why | A few facts (your place, your marks, your settings) that must survive the program being killed, written by two processes that may have the same document open. That is a transaction over a file. | Neovim's plugins are Lua, and Lua is built to be embedded: thirty-odd C files, no dependencies. |
| Source | the amalgamation: one C file and its header | the release tarball; its SHA-256, `2335b6c5...5c6fb8e6`, matches lua.org's |
| Declarations | by hand in `src/mimir/Db.zig`; `sqlite3.h` is never included | by hand in `src/galdr/lua.zig`, against Lua's defaults (64-bit integers, double floats) |
| Compiled | with the flags below | every library file but `lua.c` and `luac.c`, as C99; `liolib.c`, `loslib.c` and `loadlib.c` compile but are never opened; `LUA_USE_POSIX` everywhere but Windows |
| Without it | `-Dsqlite=false`: no download, no C, no libc on Windows. Every document opens at the top, marks last as long as the window, and `recent`, `marks` and `config` say the build has no library. | `-Dlua=false`: no plugins, and `fenrir plugins` says so. |

Tests that need a library skip rather than fail when it is turned off.

**Fetching ahead of time or offline.** `zig build --fetch=all` downloads every
dependency and stops; after that no build needs a network. Without a network,
or behind a proxy Zig cannot use, fetch the archive any way you like and hand
it to Zig:

```
curl -LO https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip
zig fetch sqlite-amalgamation-3530400.zip
# N-V-__8AAGVtrgCcOcmjrOJnagmnRyMrcKaOo09KbU-vu8w8   (must equal the pin)
zig build
```

The same works for `lua-5.4.9.tar.gz`. Only the contents are checked, so the
file can come from a mirror or a USB stick. To keep the cache elsewhere, pass
the same `--global-cache-dir DIR` to `zig fetch` and `zig build` (or set
`ZIG_GLOBAL_CACHE_DIR`), and create `DIR/tmp` first.

**Upgrading.** `zig fetch --save=sqlite <new zip url>` (or `--save=lua
<new 5.4.x tarball>`) rewrites the URL and hash; put `.lazy = true` back if it
was dropped, then run the tests. They check that SQLite opens, that
`SQLITE_DQS=0` took effect and that the schema migrates, and for Lua every type
that crosses between Zig and C, that a Zig error reaches a Lua `pcall`, and
that the sandbox is intact. SQLite's version is spelled in the file name
(3.53.4 is `3530400`). Lua 5.5 changes the API in places and is not a drop-in
change.

**SQLite's flags.** Mostly the ones SQLite recommends for a copy compiled into
one program. The choices that are this project's: it stays thread-safe,
foreign keys are enforced, extensions cannot be loaded, and a double-quoted
word is only ever a name (the legacy behaviour quietly turns a misspelt column
into a string).

```
-DSQLITE_DQS=0  -DSQLITE_THREADSAFE=1  -DSQLITE_DEFAULT_FOREIGN_KEYS=1
-DSQLITE_DEFAULT_MEMSTATUS=0  -DSQLITE_LIKE_DOESNT_MATCH_BLOBS
-DSQLITE_MAX_EXPR_DEPTH=0  -DSQLITE_OMIT_AUTOINIT  -DSQLITE_OMIT_DECLTYPE
-DSQLITE_OMIT_DEPRECATED  -DSQLITE_OMIT_LOAD_EXTENSION
-DSQLITE_OMIT_SHARED_CACHE  -DSQLITE_USE_ALLOCA
```

### Cross-compiling

Zig carries every target's libc headers and linker:

```
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
```

A cross-compiled test binary cannot run on the host (`unable to execute`), so
use this as a check that the other platform still compiles. On Linux the
binary needs glibc (for `dlopen`) and opens `libvulkan.so.1`,
`libwayland-client.so.0` and `libxkbcommon.so.0` when the window opens; none
is needed to build or for the commands that open no window.

### When the build fails

| Message | Cause, and what to do |
|---|---|
| `hash mismatch` for `sqlite` or `lua` | The archive is not the pinned release: a proxy's error page, a mirror with another version, a truncated download. Fetch by hand and compare the hash. |
| A network error fetching `sqlite` or `lua` | Fetch by hand, or build without it. |
| `failed to create temporary zip file: FileNotFound` | A `--global-cache-dir` that does not exist. Create it and its `tmp`. |
| An explicit `-Dshaders` whose compiler is missing | Install one, use `-Dshaders=spirv`, or leave the option out. |
| `-Dshaders=spirv needs .../spirv/*.spv` | A checkout without the committed SPIR-V. Run `zig build spirv` where a compiler is installed. |
| `no member named ...` in the standard library | The wrong Zig. It must be `0.16.0`. |
| Builds, but `read` says "no Vulkan loader" | Install the GPU driver. `--shot` with `--path cpu` needs no device. |

### Which path rasteriser

`-Dpath=cpu|gpu|both` decides what the *window* may draw with; `both`, the
default in every mode, lets `fenrir read --path cpu|gpu` choose and
`fenrir raster --path both` compare. A build with one refuses the other by
name rather than falling back. The CPU rasteriser is always compiled, because
`raster` and `read --shot --path cpu` use no device. The GPU path draws images
and five blend modes (normal, multiply, screen, darken, lighten); the other
eleven, and shadings, are where the CPU rasteriser is still ahead.

### Shaders

```
zig build -Dshaders=glsl    # src/gleipnir/shader/*.vert|frag, via glslc or glslang
zig build -Dshaders=slang   # src/gleipnir/shader/slang/*.slang, via slangc
zig build -Dshaders=spirv   # src/gleipnir/shader/spirv/*.spv, committed, no compiler
zig build                   # auto: glsl if a compiler is on PATH, else spirv
zig build spirv -Dshaders=glsl                 # rewrite spirv/ from the GLSL (or =slang)
zig build -Dshaders=glsl -Dglsl-compiler=glslang
zig build -Dshaders=slang -Dslangc=C:/tools/slang/bin/slangc.exe
```

An explicit choice whose compiler or files are missing fails the build; only
`auto` falls back. `fenrir read` names its source (`shaders from glslang`).
All three sources pass the same tests: each module is the stage it claims,
asks for descriptor indexing exactly where its pipeline needs it, and lays out
every storage buffer the way the Zig struct does, read back out of the
compiled SPIR-V. Pages read back from the GPU are bit-identical between the
Slang and GLSL builds. GLSL stays the default until Slang has had wider use.

`spirv/` is regenerated by hand: after changing a shader, run `zig build spirv`
before committing. A shader that `#include`s must ask for
`GL_GOOGLE_include_directive` by name, because `glslc` enables it and
`glslang` does not (tested with glslang 16.5.0). A binary built with no
compiler and no `spirv/` opens its window and draws nothing, with a message
naming `-Dshaders=spirv`.

A compiler is needed only to change a shader; the build uses the executable
alone, never an SDK's headers or libraries:

| | |
|---|---|
| Vulkan SDK | [vulkan.lunarg.com](https://vulkan.lunarg.com); `glslc` and the validation layers. `winget install LunarG.VulkanSDK`. |
| glslang | [KhronosGroup/glslang releases](https://github.com/KhronosGroup/glslang/releases); one binary, no installer. |
| A package manager | `apt install glslang-tools`, `brew install glslang`, `pacman -S shaderc` |
| Slang | [shader-slang/slang releases](https://github.com/shader-slang/slang/releases); `bin/slangc`. Tested with 2026.17.1. |

### Font backends

```
zig build -Dfreetype               # link FreeType as a glyph backend
zig build -Dstb-truetype           # compile stb_truetype (vendor the header first)
zig build -Dharfbuzz               # link HarfBuzz as the UI text shaper
zig build -Dfont-backend=freetype  # which glyph backend to try first
zig build -Dfreetype -Dfreetype-include=<prefix>/include/freetype2 -Dfreetype-lib=<prefix>/lib
```

The last form is for systems without pkg-config, which is most Windows
machines; the include directory is the one holding `ft2build.h`. The flags
decide what is linked; which backend opens a font is decided at run time, so
one build can render a page through two backends and diff them.
`fenrir fonts` prints what a binary can do.

## Using the reader

`fenrir read file.pdf` opens where you left it, fitted to the window's width.
The percentage in the status bar is the page's true physical size on this
display, scaling included. `--page` or `--zoom` overrides what was remembered.
Pages are prepared on their own thread and the frame loop never waits: a page
that is not ready is blank paper for a few frames, not a frozen window.

The reader has Vim's modes. `fenrir help read` prints all of this, and
`fenrir commands` lists every `:` command.

```
normal mode (reading)
  h j k l, arrows    move the cursor; the page follows    w b e      word forward, back, end
  ^ $                start / end of the line              escape     put the cursor away
  wheel, ctrl+wheel  scroll, zoom                         + - 0 1    zoom, fit width, 100%
  page up / down     a screen                             home end   first / last page
  space  p           next / previous page                 :          the command line
  /                  search; n N step the matches, or turn the page with no search open
  m                  highlight the selection or the cursor's line, or remove the one under it
  M                  remove every mark here               u  <C-r>   undo / redo a mark change
  ]a [a              next / previous mark                 ]c [c      next / previous comment
  click a mark       remove it                            <C-p>      the command palette
  v V i d            visual, visual line, edit, draw      q  Q       close window / the reader

visual mode (v, V)
  any motion         extend the selection                 o          go to the other end
  m y enter          highlight in the accent colour       1 .. 8     in a colour: accent, yellow,
  d x                remove the highlights it touches                green, blue, pink, orange,
  v V                leave, or switch kind                           purple, red

edit mode (i)          takes hold of the highlight at or after the cursor
  n N, j k, tab      next / previous highlight            1 .. 8     recolour it
  ]a [a, ]c [c       the same, or only those with a note  a enter    write a note (note mode)
  d x delete         delete it, take the next             escape q   back to normal

draw mode (d)          the pointer is a pen
  drag               draw a stroke on the page it began   1 .. 8     the pen's colour
  [ ]                thinner / thicker                    d q escape back; a click there erases

windows and tabpages
  <C-w>v <C-w>s      split beside / below                 <C-w>c q   close this window
  <C-w>o             close the others                     <C-w>=     equal sizes
  <C-w>h j k l       the window that way                  <C-w>w W   next / previous window
  <C-w>n <C-w>b      next / previous document here        <C-w>T     window to its own tabpage
  gt gT              next / previous tabpage; the bar appears once there are two
```

In note mode every key is text: enter keeps the note, escape drops it. A
highlight made over an existing one replaces it rather than stacking a darker
one. Every change to the marks is one step of undo (a highlight over several
lines is one step), undo reaches back through the session, and every change
is written to Mímir as it settles, so every window on the document shows it at
once and it is there next time. Fit is a mode: a fitted window refits when it
is split or resized. Dragging the line between windows resizes them.

```
$ fenrir config author "Nahid Hasan"    # signs annotations, when they exist
$ fenrir config accent yellow           # the scrollbar, the focus ring, highlights
$ fenrir recent
page    5  +312pt  /home/n/papers/An Alternative View.pdf  (An Alternative View.pdf)
```

`--shot F` writes one composed frame to a PNG. With `--path cpu` there is no
window and no device, which is how a layout is checked on a machine with no
display (it draws the page and no chrome). With `--device` the frame is drawn
by the GPU and read back from the swapchain, once every visible page is ready.

## The CLI

Vánagandr makes the rest debuggable. `fenrir help <command>` prints each
command's options.

| Command | |
|---|---|
| `info <file>` | header, trailer, xref and document information |
| `dump <file> [--obj N] [--follow] [--depth N] [--all]` | the object graph |
| `pages <file> [--verbose]` | every page and its effective geometry |
| `xref <file> [--verify]` | where every object lives; `--verify` checks each offset hits its own `N G obj` |
| `extract <file> <obj> [--raw]`, `extract <file> --page N` | a stream's decoded bytes, or a page's content stream |
| `trace <file> [--page N\|--all] [--stats\|--paths\|--glyphs\|--lines\|--text\|--find Q\|--hash]` | a page as a display list, as the text a search runs over, or as the hash `diff` compares |
| `raster <file> [--page N\|--all] [--dpi N] [--samples N] [--path stencil\|slug\|both] [--stats] [--time] [--jobs N] [-o F]` | a page rendered to a PNG on the CPU, and the benchmark |
| `read <file>...` | the reader; see above |
| `diff <a> <b> [--report] [--pair number\|text] [--output-diff DIR] [--jobs N]` | which pages of two documents differ, as diff-pdf finds them: by display-list hash, then by pixel, then by word. Without `--report`, the two side by side |
| `recent`, `config`, `marks <file>` | what Mímir remembers; `marks --add` and `--ink` write marks from a script |
| `plugins [--api]` | load the configuration and report, or print the whole `fenrir` table |
| `health` | what this build has, where it keeps things, what the configuration asked for |
| `run <script.lua> [file...]` | a plugin over documents, with no window |
| `commands [--names] [--match Q]` | every `:` command, or how the palette ranks Q |
| `fonts`, `icons [--out F]` | the font backends; the icon registry and a sheet of it |
| `rects`, `ui`, `view [--probe]` | the rect pipeline, the interface to a PNG, the same on the GPU; `--probe` lists devices |

`raster` reports what it could *not* draw rather than letting a page with a
hole in it look finished:

```
$ fenrir raster paper.pdf --page 8 --dpi 110
page 8  935x1210  0 fills  1 strokes  0 clips  103515 segments
         0 annotations drawn, 8 skipped
         6 images decoded
wrote page-8.png
2833 of 2833 glyphs drawn, 0 blank, 0 invisible
every mark on the page was drawn
```

- `--path both` renders through both rasterisers and reports the difference in
  levels of 255, writing `-slug` and `-diff` images. The difference is ink only
  along glyph edges, and shrinks as the stencil sample count rises: two
  implementations that agree where every shape is and differ only in
  antialiasing.
- `--ascii x,y,w,h` prints a window of the result as text, one character a
  pixel. A one-pixel seam is invisible in an image viewer and unmistakable
  there.
- `--fonts` lists which backend opened each font and how its encoding was
  resolved, which is where "why is this page blank" is usually answered.
- `trace` answers the other half: is the interpreter wrong, or the rasteriser?
- `view --probe` enumerates the Vulkan devices without opening a window, so it
  works over ssh. Its `indexing` line decides whether a frame is one draw call
  or one per run of instances sharing a texture.

## Profiling

Nothing is optimised on the strength of how the code reads.
[`OPTIMIZING.md`](OPTIMIZING.md) has the method, the worklist and the ledger.

- **`--time`** on `raster` and `read` is the first stop. It splits the run
  into interpret, canvas, fonts and render, and hashes the pixels in the same
  pass, so one command says where the time went and whether the picture
  changed. `--stats` keeps the PNG encoder and the disk out of it.

  ```
  $ fenrir raster <file> --all --stats --time
  time 2237.43ms over 26 pages  interpret 13.90  canvas 154.10  fonts 6.41  render 2063.02  hash bf68db5063ccf734
  ```

  Keep both binaries and run them interleaved: this machine drifts several per
  cent in a few minutes, more than most wins. `read --time` names each startup
  stage, from the library to the first page on screen.
- **A sampling profiler** (Superluminal, VTune, Windows Performance Recorder)
  on a `ReleaseSafe` build of `fenrir raster <file> --all --stats`. That build
  is full speed and keeps frame pointers. The command does no GPU work, which is
  what makes it the standard workload.
- **RenderDoc** only for the GPU side: the analytic pipeline under
  `read --path gpu`, whether the frame loop does what `src/lyngvi/` claims
  (one draw call per layer, no per-frame allocation), and GPU timings. Launch
  `fenrir read <file> --path gpu` from RenderDoc and press F12; `--validate`
  turns on the validation layers, the cheaper check. RenderDoc cannot see
  `raster` or `--shot --path cpu`, and a capture perturbs its frame, so read
  the timings off `--time`.

## Plugins

Galdr (a spell, runes written or words sung) follows Neovim: Lua, an
`init.lua`, a directory of plugins, one `fenrir` table. It embeds PUC-Rio
Lua 5.4, not LuaJIT; see below.

```
<config>/init.lua                 run first
<config>/plugins/<name>.lua       then each plugin, in order of name
<config>/plugins/<name>/init.lua    (a directory plugin; plugin.lua beside it is its manifest)
<config>/lua/<module>.lua         what require("module") finds; "a.b" is lua/a/b.lua
```

`<config>` is `%APPDATA%\fenrir` on Windows, `~/Library/Application
Support/fenrir` on macOS, and `$XDG_CONFIG_HOME/fenrir` or `~/.config/fenrir`
elsewhere. `FENRIR_CONFIG` or `--config DIR` points elsewhere; `--clean` runs
none. A plugin that fails to load is reported and skipped, and the reader
still opens.

```lua
-- init.lua

-- <C-d> and <C-u> page down and up, as in a pager.
fenrir.keymap("n", "<C-d>", function() fenrir.exec("page +1") end, "next page")
fenrir.keymap("n", "<C-u>", function() fenrir.exec("page -1") end, "previous page")

-- G goes to the last page; a string action runs as a : command line.
fenrir.keymap("n", "G", function() fenrir.go(fenrir.document().pages) end)
fenrir.keymap("n", "<C-t>", "1", "the first page")

-- :Toc 3 remembers page 3 as this document's table of contents, and :Toc goes there.
fenrir.command("Toc", function(args)
  local key = "toc." .. fenrir.document().path
  if args ~= "" then fenrir.store.set(key, args) end
  local page = tonumber(fenrir.store.get(key) or "")
  if page then fenrir.go(page) else fenrir.notify("no table of contents set: :Toc N") end
end, "go to the table of contents")

-- Say where each new mark was made.
fenrir.on("AnnotationAdd", function(e)
  fenrir.notify(("marked page %d"):format(e.page))
end)
```

`fenrir plugins` loads a configuration with no window and prints what loaded,
what each plugin asked to reach, what failed and why, and the keys and
commands registered; it exits non-zero if anything failed. Inside the reader,
`:plugins` and `:messages` say the same.

### The `fenrir` table

`fenrir plugins --api` prints every function with its arguments. Pages, lines
and columns count from 1; positions are PDF points from the page's bottom-left
corner, the numbers `fenrir marks` prints.

A plugin may declare a manifest, `fenrir.manifest{ about, version,
capabilities = {...} }`, or `plugins/<name>/plugin.lua` returning the same
table. Its `fenrir` table then holds only what it asked for. The rest is not
refused at call time; it is `nil`. A plugin with no manifest sees everything.

| Capability | Functions |
|---|---|
| always | `manifest`, `on(event, pattern?, fn, group?)`, `off(id)`, `clear(group)`, `store.get/set` (strings kept in Mímir, in a key space of the plugin's own) |
| `document.read` | `document()`, `page()`, `cursor()`, `selection()`, `highlights()` (every mark; `kind` is `"block"` or `"ink"`) |
| `document.write` | `highlight{page, x0, y0, x1, y1, color?, note?}`, `unhighlight(id)`; saved and undone like any other mark |
| `ui` | `notify`, `exec`, `keymap(modes, key, action, desc?)`, `unmap`, `command(name, fn, desc?, icon?)`, `go`, `zoom`, `mode`, `rail{...}`, `unrail`, `setting{...}`, `panel{...}`, `refresh` |
| reserved | `network`, `filesystem`, `clipboard`, `signature`, `redaction`: names only, nothing behind them yet |

`keymap` modes are `"n"`, `"v"`, `"e"`, `"d"`, several (`"nv"`), or a table. A
key is one key or chord: `"g"`, `"<C-k>"`, `"<A-x>"`, `"<Space>"`, `"<lt>"`. A
plugin's binding comes before the built-in one, `<C-w>` included; a plugin
command cannot redefine a built-in one. Rail buttons and panels name icons
from the registry, never a path. Globals: `print` (to the message line),
`require` (only `lua/` under the configuration directory), `load` (source
only), `fenrir.version`, `fenrir.lua` (`"Lua 5.4"`).

### Events

`fenrir.on(event, pattern, fn, group)`, as Vim's autocommands: `pattern` is a
glob on the document's path, and a `group` clears together. Handlers run as
coroutines and may yield.

| Event | Argument | When |
|---|---|---|
| `Start` | — | every plugin loaded, the window open |
| `DocOpen` | `{path, title, pages}` | each document, after the plugins load |
| `PageChanged` | `{page}` | the focused window's page changed |
| `ModeChanged` | `{mode}` | the mode changed |
| `SelectionChanged` | `{from, to}` or neither | the selection moved or was cleared |
| `AnnotationAdd`, `AnnotationRemove`, `AnnotationChange` | the mark | from a key, the mouse, undo, or a plugin |
| `PageRender` | `{page}` | a page finished rasterising: once per page, on the frame thread |
| `Quit` | — | the reader is closing |
| `ThemeChanged`, `DocSave`, `FormFieldFocus`, `BeforeRedact` | | reserved; nothing fires them yet, and `fenrir health` says so |

A handler that causes its own event is cut off at four levels.

### What a plugin cannot do

A plugin directory is where people paste code from strangers, and a PDF reader
opens files from strangers:

- **No files, processes or native code.** No `io`, `os`, `package`, `debug`,
  `dofile` or `loadfile`; `require` refuses a name with `/` or `..`. `string`,
  `table`, `math`, `utf8` and `coroutine` are there.
- **No bytecode.** Lua does not verify it, and a crafted chunk can crash the
  interpreter.
- **No global `fenrir`.** Every chunk has an environment of its own, so a
  narrowed plugin cannot reach a wider table through `_G`.
- **64 MB** for all plugins together; past it, an allocation is an ordinary
  "not enough memory" error.
- **About fifty million instructions** per call into Lua (a few hundred
  milliseconds). `while true do end` freezes the reader for a moment, not
  forever.

Every call is protected: an error shows its first line on the message line,
keeps its traceback for `:messages`, and the reader carries on. Not there yet:
key sequences (`gg`, `<leader>x`), timers, drawing on the page, and the page's
text.

### Why Lua 5.4 and not LuaJIT

Neovim's Lua *is* LuaJIT, whose permanent interface is Lua 5.1. LuaJIT would
buy speed (a tight numeric loop is several times faster) and source
compatibility with Neovim plugins. It would cost two things:

- **The sandbox.** LuaJIT's `ffi` calls any C function in the process and reads
  and writes any memory. PUC Lua lets this program claim "no files, no
  processes, no native code" by leaving three library files unopened; LuaJIT
  would need `ffi` and `jit` removed and re-audited every release.
- **The build.** PUC Lua is thirty-odd C files that `build.zig` compiles for any
  target. LuaJIT is a two-stage DynASM build, and only for architectures it
  has a backend for.

Speed did not decide it. Measured here, ReleaseFast, one core, per loop
iteration:

| loop body | per iteration |
|---|---|
| `s = s + i` | 12 ns |
| `n = n + f()`, a Lua function | 60 ns |
| `if fenrir.mode() then n = n + 1 end`, a call into the reader | 81 ns |

Loading a configuration is about 10 ms. A keypress runs a handler that makes a
handful of calls, single-digit microseconds against a 16 ms frame. When plugins
gain page text, drawing and timers they will loop over real data, and this
should be measured again. The sandbox objection does not expire: a move would
be to LuaJIT's interpreter with the FFI compiled out.

`fenrir.lua` is `"Lua 5.4"`, so a plugin can branch. What bites someone
arriving from Neovim:

| LuaJIT / 5.1 | here, 5.4 |
|---|---|
| `unpack(t)` | `table.unpack(t)` |
| `loadstring(s)` | `load(s)`, source only |
| `setfenv`, `getfenv`, `module` | gone; use an explicit table |
| `bit.band(a, b)` | `&`, `\|`, `~`, `<<`, `>>` |
| `math.pow(a, b)`, `math.mod` | `a ^ b`, `a % b` |
| `tostring(4 / 1)` is `"4"` | `"4.0"`, since 5.3 split integers from floats |
| `ffi`, `jit` | not there, on purpose |

The other way round, `//`, `<const>`, `<close>` and the bitwise operators are
5.4 syntax, so a plugin using them will not load under LuaJIT.

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

## Design notes

The decisions that are load-bearing, and why.

**Gelgja, the display list.** The interpreter records a list rather than
calling a live backend, so a page is cacheable, diffable and testable with no
GPU. Curves are kept, not flattened, because flattening needs a tolerance in
device pixels, which changes with every zoom. The CTM is baked into path
points, but a stroke keeps it: the pen is a circle in user space, an ellipse
under a non-uniform matrix, and a zero width means "as thin as the device can
draw". Everything lives in flat shared arrays addressed by `Range`, so ten
thousand paths cost one allocation per array. There is no SVG backend: SVG
stops being trustworthy exactly where PDF gets hard (blend modes, soft masks,
shading types 4–7, text render modes, dash phase). Still to come is a
regression suite pixel-diffed against `mutool draw` or `pdftoppm`.

**Gleipnir, pixels.**
- One 96-byte instance draws every rectangle the interface has (panels,
  borders, shadows, image tiles, and glyphs from the atlas) as a rounded box
  from a signed distance field. That makes one draw call a frame.
- The clip lives in the instance, not in `vkCmdSetScissor`. Sixteen bytes
  buy back a draw call per clip change, and the vertex shader shrinks the quad
  to the clip, so clipped fragments are never generated.
- The fragment shader reads the instance from the storage buffer rather than
  varyings, because a bilinear corner gradient is not two linear functions
  over a quad's triangles.
- The transform stack is scale and offset. `Xform.fromTransform` returns null
  for a matrix it cannot honour; `/Rotate` lives in the projection; anything
  truly rotated is a path.
- Colours are sRGB bytes blended in linear light against an `_SRGB`
  swapchain. Light text on dark reading thin is fixed by stem darkening, not
  by blending in the wrong space.
- For paths the analytic rasteriser won over stencil-and-cover: one pass
  instead of two, no multisampled attachment, and an antialiased clip that a
  stencil bit cannot express. Two rays leave each pixel centre, along x and
  along y, and each sums its crossings ramped across the pixel. They are
  blended by how close each came to an edge, so a vertical edge takes the x
  ray's exact answer. Curves are banded and sorted by reach, so a fragment
  tests one band and stops early. The root solve is the numerically stable
  one, because page units and em units are three orders apart.
  `pathpipe.zig` and `raster.zig` stay as the argument and the CPU oracle.
- A test reads buffer layouts back out of the compiled SPIR-V. A std430
  struct eight bytes longer than the Zig one draws a page as its glyphs
  scattered across it; that happened.

**Týr, fonts.**
- There are two interfaces, because FreeType cannot decide that `fi` is one
  glyph and HarfBuzz cannot draw one. `Face` takes a glyph index and returns
  an outline and advance. `Shaper` takes a string and returns positioned
  glyphs.
- A PDF page never needs shaping: the producer shaped it years ago and baked
  the answer into `Tj` and `TJ`. HarfBuzz is only for text fenrir composes.
- Which backends exist is a build-time fact; which opens a font is decided at
  run time, so two can render one page in one process and be diffed. There is
  one `comptime` conditional, in `registry.zig`.
  - Comptime dispatch was rejected because it makes that diff impossible.
  - `std.DynLib` at startup was rejected because it gives no C ABI checking,
    and stb_truetype is a header, not a library.
- Backends declare capabilities (`fenrir fonts`):
  ```
  truetype   truetype names cmap
  cff        cff names
  type1      type1 names
  fallback   truetype cff type1
  ```
  The format is sniffed from the bytes, not trusted from the descriptor,
  because `/FontFile2` holding CFF is not rare. Selection tries the preferred
  backend, then the rest, then the fallback, so opening a font fails only
  when memory runs out.
- The atlas is keyed by `(face, glyph, size, subpixel x)`, with three buckets
  a pixel. Rounding each glyph to a pixel makes letter gaps wobble by more
  than a stem; rounding the run blurs it. Baselines are snapped. It packs by
  skyline into a texture of fixed width and growing height, and clears at the
  cap at a frame boundary. There is no LRU: touching a timestamp per glyph
  per frame to guard a resource that is not scarce is not worth it.
- Týr's own scan converter uses signed-area accumulation (after `font-rs`),
  with a flatness of a fiftieth of a pixel. A tenth shaved a quarter of a
  percent off every bowl; a test measures a circle against πr².
- `/Widths` and `/W` come from the PDF and win over the font's advances.

**Þviti, the interface.**
- Immediate-mode call sites over a retained box cache, after the RAD
  Debugger. A box's key is a hash of its call-site string seeded with its
  parent's. `"Save##toolbar"` shows `Save` and keys on the whole string;
  `"42 items###count"` keys on `count` alone. Keyless boxes, most of a tree,
  live in the frame arena.
- Sizing is semantic: a box has an opinion about its size and a strictness
  that says how much it will give up. Five passes per axis solve it, and a
  shortfall is shared by what each child is willing to lose, which is the only
  rule independent of build order. Shrinking can invalidate a descendant's
  percentage; like RAD, this accepts that and offers an overflow flag, which
  is what a scroll view uses.
- Hover is resolved after layout, against this frame's geometry, for the next
  frame's signals. "The box drawn on top" and "the box that gets the mouse"
  are then the same box without sorting.
- There is one style stack, merged a field at a time, plus one-shot overrides
  that clear after the next box. The classic immediate-mode bug is a colour
  set for one button that applies to the next forty.
- Vulkan does not push toward retained widgets. Per-frame data is a few
  hundred kilobytes; what Vulkan punishes is pipeline churn, and there is one
  pipeline. The box cache is also the stable tree a screen reader would need.
- The list widget builds only the rows it can see. The demo sidebar went from
  163 boxes and 1,599 culled instances to 71 and 27.

**Lyngvi, the platform.**
- `Window` is a small vtable, and a test keeps it at fifteen entry points or
  fewer. Hit testing, focus and hover belong to Þviti.
- X11 was stubbed from day one, because an interface with one implementor is
  not one. The stub is why wheel movement arrives in pixels and why
  `scroll_line_pixels` exists.
- Vulkan is declared by hand and opened by name, so a machine with no driver
  gets a sentence rather than a failure to start. Structures passed to the
  driver are byte-exact. Structures it fills may be larger:
  `VkPhysicalDeviceLimits` is four named fields and an oversized tail.
- Device functions come from `vkGetDeviceProcAddr`, which avoids a trampoline
  per call. They are filled into three dispatch tables by `inline for` over the
  tables' fields, which leaves no hand-pasted name to get wrong.
- Every decision is a pure function in `choose.zig`, tested on cases this
  machine never produces:
  - no sRGB format;
  - a `0xFFFFFFFF` extent;
  - no maximum image count (zero means no maximum; clamping to it asks for
    zero images);
  - one more image than the minimum (exactly the minimum makes every acquire
    wait on the compositor);
  - a render-finished semaphore per swapchain *image*, not per frame in
    flight.
- The instance buffer is mapped once, and host-visible memory that is also
  device-local is preferred (resizable BAR). Glyph uploads ride in the
  frame's own command buffer.
- The mouse is state, the keyboard an ordered list, and the wheel
  accumulates. `WM_CHAR`'s UTF-16 surrogates are paired. Text bytes are
  double-buffered, because Windows runs a modal loop inside a window drag. A
  test found that one: every byte came back `0xaa`.

## Damage tolerance

Real files are broken constantly, so recovery is a feature. Each case is
covered by a test or the corpus:

- a wrong or indirect `/Length` falls back to scanning for `endstream`;
- a `/Prev` that misses by a few hundred bytes (any repaired or re-saved file)
  is found by searching nearby;
- a stale object offset is found by rescanning for its header;
- a table that parses but reaches no page tree is rebuilt by scanning for
  `N G obj`;
- no usable trailer recovers `/Root` from the object whose `/Type` is
  `/Catalog`;
- a missing, unreachable or cyclic page tree falls back to scanning for
  `/Type /Page` and climbing `/Parent` for inherited attributes;
- untyped page-tree nodes are classified by shape;
- a reversed or degenerate `/MediaBox` is normalised or replaced.

Across 40 real documents (PDF 1.2 to 1.7, 6,511 pages) every one opens, and
every `/Count` agrees with the leaves the walk finds. Truncated, prepended,
zero-holed and random inputs do not crash; a file with 19 junk bytes
prepended, which breaks every offset, still reads completely.

## Not implemented

- **Encryption.** Detected and reported; strings and streams read as
  ciphertext. An empty user password, which most encrypted files have, is the
  next thing worth adding.
- **Two interpreter approximations**, each in one named function. A `/Type0`
  font with a predefined non-Identity CMap decodes two bytes at a time, which
  is right, but with the wrong CID mapping for CJK. Clipping text render modes
  (`Tr 4`–`7`) clip to a box per glyph.
- **Fonts a document does not embed** are substituted with a face from this
  machine, not matched. Positions still come from `/Widths`.
- **JPEG 2000, CCITT and JBIG2** are not decoded, so a fax-coded or JBIG2 scan
  shows only its OCR layer. Progressive JPEG is refused. An `/Indexed` inline
  image comes out as the grey of its indices.
- **Shadings and tiling patterns** resolve to a `Paint` but are not painted;
  they are counted and skipped.
- **Transparency groups** are exact for a non-isolated, non-knockout group
  whose contents do not overlap (a highlight, a stamp) and wrong otherwise.
- **On the GPU**, five of sixteen blend modes; the rest draw as normal and are
  counted. Images are kept at four texels a point, so a photograph past 400%
  is softer than on the CPU.
- **Annotations** draw from their appearance streams only. One without `/AP`
  is skipped; none is interactive, and links are not clickable. fenrir's own
  marks live in Mímir and are never written into the PDF. A note shows on the
  status line and as a tab on its highlight, not as text on the page.
- **The standard-14 metrics**: a simple font with no `/Widths` advances half
  an em.
- **The platform**: no IME, tree widget, drag and drop, file dialogs, menus or
  clipboard; X11 is a stub; Wayland is tested but has never met a compositor.
- **Word motions** find boundaries from glyph spacing, since most PDFs draw no
  spaces, so a letter-spaced line can mislead them. There is no `<C-w>` resize
  command; dividers are dragged.

## Porting to Android

Nothing targets Android, but most of a port is done by accident: the platform
is one module behind a vtable and everything above it is portable Zig.

**What crosses unchanged:**
- everything above Lyngvi, which makes no system calls beyond allocation;
- the Vulkan loader, opened by name (`libvulkan.so` is already on the list);
- SQLite and Lua, compiled from source for the target;
- the committed SPIR-V;
- the rasterising thread, which is `std.Thread`.

```
zig build -Dtarget=aarch64-linux-android -Dshaders=spirv -Doptimize=ReleaseFast \
    --sysroot $NDK/toolchains/llvm/prebuilt/<host>/sysroot
```

**What has to be written:**
- **A window backend**, `src/lyngvi/android.zig`, over `ANativeWindow*` and
  `VK_KHR_android_surface`. Smaller than Wayland's: a C header, not a wire
  protocol.
- **A library entry point**: `libfenrir.so` with `android_main`, and no CLI.
- **Surface loss**: tear down and rebuild the surface as well as the
  swapchain on `APP_CMD_TERM_WINDOW` and `APP_CMD_INIT_WINDOW`.
- **Touch**, which is a design and not a port: drag, fling, pinch,
  long-press, and buttons for the modes and `:`. `Session.apply` takes a
  `keys.Command`, never a keystroke, so a gesture can use the same entry point
  as a key.
- **Files as descriptors** from the Storage Access Framework. `Document.open`
  takes bytes, but Mímir keys documents on a path.
- **Somewhere to write.** Config and database directories come from
  `Context.getFilesDir()` over JNI. Plugins are then reachable only over
  `adb` or a file picker.
- **Substitute fonts** from `/system/fonts`, whose family names differ.

**What to expect:**
- The practical floor is Vulkan 1.1 (Android 10, API 29); descriptor
  indexing is not universal on older drivers. Run `view --probe` first.
- The CPU rasteriser takes about 200 ms for a dense page at 96 dpi on one
  desktop core.
- It needs 26 bytes a pixel at eight samples: about 67 MB for a 1080×2400
  screen before any document. The GPU path avoids that.

## Reference

ISO 32000-2 (PDF 2.0) is the specification, free from the PDF Association at
[pdfa.org](https://pdfa.org/sponsored-standards/). Section references in the
source point at it. `qpdf --qdf --object-streams=disable in.pdf out.pdf`
rewrites any file into a readable form to check this parser against.

The binding of Fenrir is told in Gylfaginning 34 of Snorri Sturluson's Prose
Edda. Gleipnir's six ingredients were the sound of a cat's footfall, the
beard of a woman, the roots of a mountain, the sinews of a bear, the breath
of a fish, and the spittle of a bird. They no longer exist, having been used
up in the making.

## Loose ends

- Final goal: remove the glslc dependency, using glslang's
  [AST → SPIR-V back end](https://github.com/khronosGroup/glslang#ast---spir-v-back-end).
- Consume
  [async-io-examples/example8.zig](https://codeberg.org/andrewrk/async-io-examples/src/branch/main/example8.zig).
- Inline images.
- **Why not XInput:** it misses samples when the frame rate is low and needs a
  thread of its own ([Casey Muratori](https://www.youtube.com/watch?v=ONMSW1XvuVU)).
