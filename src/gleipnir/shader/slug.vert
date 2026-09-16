#version 450
#extension GL_GOOGLE_include_directive : require
#include "slug.glsl"

// No vertex buffer and no index buffer, the same as the rect pipeline: the
// draw is `vkCmdDraw(cmd, 4, n, 0, first)` with a triangle strip, and the
// quad comes out of gl_VertexIndex.
//
// This is the part that most distinguishes an analytic path pipeline from
// stencil-and-cover. There the geometry *is* the path -- a fan of triangles
// per contour, uploaded per frame, drawn twice. Here the geometry is four
// corners of the path's bounding box, and the outline itself lives in a
// storage buffer that is uploaded once and read by whichever fragments
// happen to land on it. A zoom changes a matrix; nothing is re-tessellated,
// nothing is re-uploaded, and there is no second pass.
//
// Slug's reference dilates each vertex along its normal by half a pixel,
// solved through the MVP matrix. The quad here is built in device space
// already, from the mapped corners, so the same dilation is a pixel added to
// an axis-aligned box.

layout(location = 0) flat out uint v_id;

void main() {
    Instance it = instances[gl_InstanceIndex];

    // An image covers the unit square; a path covers its header's box.
    vec2 lo_p = vec2(0.0);
    vec2 hi_p = vec2(1.0);
    if ((it.flags & FLAG_IMAGE) == 0u) {
        PathHeader h = headers[it.header];
        lo_p = vec2(h.min_x, h.min_y);
        hi_p = vec2(h.max_x, h.max_y);
    }

    // The box has four corners in path space and they are not axis aligned
    // once the transform has a rotation in it, so the quad is the box of the
    // four mapped corners rather than the mapped box.
    vec2 c0 = applyXform(it.xform, it.translate, lo_p);
    vec2 c1 = applyXform(it.xform, it.translate, vec2(hi_p.x, lo_p.y));
    vec2 c2 = applyXform(it.xform, it.translate, hi_p);
    vec2 c3 = applyXform(it.xform, it.translate, vec2(lo_p.x, hi_p.y));

    vec2 lo = min(min(c0, c1), min(c2, c3)) - 1.0;
    vec2 hi = max(max(c0, c1), max(c2, c3)) + 1.0;

    // The clip is applied by shrinking the quad, as in the rect pipeline: the
    // fragments outside it are never generated.
    vec2 p0 = max(lo, it.clip.xy);
    vec2 p1 = max(min(hi, it.clip.zw), p0);

    vec2 uv = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));
    vec2 pos = mix(p0, p1, uv);

    v_id = uint(gl_InstanceIndex);

    // Vulkan clip space has y down, matching the pixel coordinates above.
    gl_Position = vec4(pos / push.viewport * 2.0 - 1.0, 0.0, 1.0);
}
