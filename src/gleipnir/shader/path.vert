#version 450
#extension GL_GOOGLE_include_directive : require
#include "path.glsl"

// One attribute, eight bytes, and the same shader for both passes of
// stencil-then-cover: the stencil pass feeds it the fan triangles and the
// cover pass feeds it the bounding box, and neither needs to know which it is.
// The two passes differ only in pipeline state, which is the point of the
// technique -- the geometry is uploaded once and the winding rule is a
// property of the stencil ops rather than of the vertices.

layout(location = 0) in vec2 in_pos;

void main() {
    vec2 p = pathToDevice(in_pos);

    // Vulkan clip space has y down, matching the pixel coordinates the rest of
    // the renderer works in, so there is no flip here. The one in the
    // page-to-screen transform is the only one.
    gl_Position = vec4(p / push.viewport * 2.0 - 1.0, 0.0, 1.0);
}
