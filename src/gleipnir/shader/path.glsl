// Shared between path.vert and path.frag.
//
// The path pipeline has no instance buffer and no per-vertex data beyond a
// position. Everything else about a path -- where it sits on screen, what
// colour it is -- is a push constant, because stencil-then-cover already costs
// two draw calls per path and there is nothing to batch across. That is the
// whole difference from the rect pipeline: rects amortise state across ten
// thousand instances, paths cannot amortise anything, so the cheapest way to
// hand over 48 bytes wins.
//
// Must stay byte-identical to `pathpipe.PushConstants` in Zig. The order here
// is chosen for std430 alignment, not for readability: the two vec4s come
// first so neither needs padding in front of it, and the two vec2s pack into
// the last 16 bytes.

layout(push_constant) uniform Push {
    vec4 xform;     // a, b, c, d of the page-to-device matrix
    vec4 color;     // premultiplied, linear light
    vec2 translate; // e, f of the same matrix
    vec2 viewport;  // framebuffer size in pixels
} push;

// PDF's matrix convention, row vectors: [x y 1] * M. Same arithmetic as
// `geom.Transform.apply` in Zig, and the same argument for keeping it --
// transposing it here would be invisible until something rotated.
vec2 pathToDevice(vec2 p) {
    return vec2(push.xform.x * p.x + push.xform.z * p.y + push.translate.x,
                push.xform.y * p.x + push.xform.w * p.y + push.translate.y);
}
