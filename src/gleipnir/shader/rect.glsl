// Shared between rect.vert and rect.frag.
//
// This struct must stay byte-identical to `rect.Instance` in Zig. The offsets
// are asserted on the Zig side at comptime; there is nothing that can check
// them from here, so the two declarations are kept in the same order with the
// same names and any change is made to both in one edit.
//
// std430 rather than std140: every member here is already 16-byte aligned, so
// the two layouts agree on offsets, but std140 would round the array stride up
// and std430 leaves it at 96, which is what Zig's `@sizeOf` reports.

struct Instance {
    vec4  dst;      // min x, min y, max x, max y, in device pixels
    vec4  src;      // normalised texture coordinates for the same four sides
    vec4  clip;     // the scissor, in device pixels
    vec4  radius;   // corner radii clockwise from top left, already clamped
    uvec4 color;    // corner colours, sRGB-encoded RGBA8, red in the low byte
    float border;   // ring thickness inside the edge; 0 fills
    float softness; // shadow radius; 0 still antialiases
    uint  texture_id;
    uint  flags;
};

layout(std430, set = 0, binding = 0) readonly buffer Instances {
    Instance instances[];
};

layout(push_constant) uniform Push {
    vec2 viewport; // framebuffer size in pixels
} push;

const uint FLAG_TEXTURED      = 1u;
const uint FLAG_ALPHA_TEXTURE = 2u;
