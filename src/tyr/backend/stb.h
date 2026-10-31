/* What `@cImport` used to take, now that translate-c is a build step.
   STB_TRUETYPE_IMPLEMENTATION and STBTT_STATIC are defined by the step, as
   `@cDefine` defined them, so this header is the implementation as well as the
   declarations. See `cHeader` in build.zig, and backend/stb.zig. */
#include <stb_truetype.h>
