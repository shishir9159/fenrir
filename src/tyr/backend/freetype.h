/* What `@cImport` used to take, now that translate-c is a build step.
   See `cHeader` in build.zig, and backend/freetype.zig. */
#include <ft2build.h>
#include <freetype/freetype.h>
#include <freetype/ftoutln.h>
