#version 450
#extension GL_GOOGLE_include_directive : require
#include "path.glsl"

// Deliberately trivial. All the shape is in the stencil buffer by the time
// this runs, so the cover pass is a flat fill through a stencil test, and the
// stencil pass runs this with the colour write mask at zero and throws the
// result away.
//
// Antialiasing is the multisample resolve, not anything here. A signed
// distance field is the right answer for a rounded box and the wrong one for
// an arbitrary outline: there is no closed form for the distance to a cubic,
// and the numerical ones cost more per pixel than four samples do.

layout(location = 0) out vec4 out_color;

void main() {
    // Premultiplied on the CPU, so the blend state is ONE /
    // ONE_MINUS_SRC_ALPHA and matches the rect pipeline exactly. Two pipelines
    // that disagree about premultiplication composite correctly on their own
    // and wrongly against each other, which is the kind of bug that only shows
    // up where a translucent panel overlaps a page.
    out_color = push.color;
}
