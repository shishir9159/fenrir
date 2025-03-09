#version 450
#include "rect.glsl"

// No vertex buffer, no index buffer, no vertex attributes. The draw is
// `vkCmdDraw(cmd, 4, instance_count, 0, 0)` with a triangle-strip topology,
// and the quad's four corners come out of gl_VertexIndex:
//
//     0 -> (0,0)   1 -> (1,0)
//     2 -> (0,1)   3 -> (1,1)
//
// which a strip turns into the two triangles (0,1,2) and (1,2,3).

layout(location = 0) flat out uint v_id;

void main() {
    Instance it = instances[gl_InstanceIndex];

    // Grow for the soft falloff, or a shadow gets sliced off square at its own
    // rectangle. 2 * softness is where coverage() reaches zero; the 1.0 floor
    // is the antialiasing ramp on a hard edge.
    float pad = max(it.softness * 2.0, 1.0);

    // The clip is applied here, by shrinking the quad, rather than by a
    // scissor. That is the whole reason a frame is one draw call: instances
    // with different clips sit next to each other in the buffer with no state
    // change between them. It is also less work than a scissor test, because
    // the clipped-away fragments are never generated.
    vec2 p0 = max(it.dst.xy - pad, it.clip.xy);
    vec2 p1 = min(it.dst.zw + pad, it.clip.zw);

    // A clip that excludes the rect entirely leaves p1 below p0, which would
    // otherwise rasterise as an inside-out quad rather than as nothing.
    p1 = max(p1, p0);

    vec2 uv  = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));
    vec2 pos = mix(p0, p1, uv);

    // Only the instance index is interpolated: the fragment shader reads the
    // instance itself out of the same buffer. Passing the fields as varyings
    // instead would need a dozen of them, and the four corner colours could
    // not be interpolated correctly anyway -- a bilinear function over a quad
    // is not two linear functions over its triangles, and the diagonal shows.
    v_id = uint(gl_InstanceIndex);

    // Vulkan clip space has y down, matching the pixel coordinates above, so
    // there is no flip here. The one in the page-to-screen transform is the
    // only one in the renderer.
    gl_Position = vec4(pos / push.viewport * 2.0 - 1.0, 0.0, 1.0);
}
