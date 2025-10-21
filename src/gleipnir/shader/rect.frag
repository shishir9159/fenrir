#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_GOOGLE_include_directive  : require
#include "rect.glsl"

// A transliteration of src/gleipnir/sdf.zig. Same functions, same names, same
// order. Every constant below is covered by a test on the Zig side, so when a
// corner comes out wrong on a device the arithmetic is already ruled out.
//
// One unbounded array of sampled images, indexed per instance, is what lets a
// glyph atlas, an icon sheet and a decoded page image appear in the same draw
// call. It needs descriptorIndexing (Vulkan 1.2 core). On a device without it
// the fallback is DrawList.textureRuns(): the frame splits into runs of one
// texture, this array becomes a single `texture2D`, and nothing else changes.

layout(set = 0, binding = 1) uniform texture2D textures[];
layout(set = 0, binding = 2) uniform sampler   samp;

layout(location = 0) flat in  uint v_id;
layout(location = 0) out vec4 out_color;

float sdRoundedBox(vec2 p, vec2 half_size, vec4 r) {
    // The quadrant p falls in picks its radius. y is down, so a negative y is
    // the top of the rect. Component order is tl, tr, br, bl.
    float rad = (p.y < 0.0) ? ((p.x < 0.0) ? r.x : r.y)
                            : ((p.x < 0.0) ? r.w : r.z);
    vec2 q = abs(p) - half_size + rad;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

float ring(float d, float thickness) {
    if (thickness <= 0.0) return d;
    float h = thickness * 0.5;
    return abs(d + h) - h;
}

float coverage(float d, float softness, float pixel) {
    float w = max(softness * 2.0, pixel);
    float t = clamp(0.5 - d / w, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

vec3 srgbToLinear(vec3 s) {
    // Blending happens in linear light, because the swapchain is an _SRGB
    // format and the hardware decodes on read and encodes on write. Note the
    // known cost: antialiased text blended in linear light looks thinner when
    // it is light on dark. The fix for that is stem darkening in the glyph
    // atlas, not blending in the wrong space.
    return mix(s / 12.92,
               pow((s + 0.055) / 1.055, vec3(2.4)),
               greaterThan(s, vec3(0.04045)));
}

vec4 corner(uint packed_color) {
    vec4 c = unpackUnorm4x8(packed_color);
    return vec4(srgbToLinear(c.rgb), c.a);
}

void main() {
    Instance it = instances[v_id];
    vec2 p = gl_FragCoord.xy;

    vec2 center    = (it.dst.xy + it.dst.zw) * 0.5;
    vec2 half_size = (it.dst.zw - it.dst.xy) * 0.5;

    float d = sdRoundedBox(p - center, half_size, it.radius);
    d = ring(d, it.border);

    // fwidth(d) is 1.0 for an unscaled field, which is what the CPU reference
    // passes. It is here so a global zoom could move onto the GPU without the
    // edges going soft or crunchy.
    float cov = coverage(d, it.softness, fwidth(d));
    if (cov <= 0.0) discard;

    vec2 t = clamp((p - it.dst.xy) / max(it.dst.zw - it.dst.xy, vec2(1e-6)), 0.0, 1.0);
    vec4 c = mix(mix(corner(it.color.x), corner(it.color.y), t.x),
                 mix(corner(it.color.w), corner(it.color.z), t.x),
                 t.y);

    if ((it.flags & FLAG_TEXTURED) != 0u) {
        vec2 uv = mix(it.src.xy, it.src.zw, t);
        vec4 s = texture(sampler2D(textures[nonuniformEXT(it.texture_id)], samp), uv);
        if ((it.flags & FLAG_ALPHA_TEXTURE) != 0u) {
            // A coverage atlas: the texture decides how much, the instance
            // decides what colour. One atlas serves every colour of text on
            // the screen.
            c.a *= s.r;
        } else {
            c.rgb *= srgbToLinear(s.rgb);
            c.a   *= s.a;
        }
    }

    // Premultiplied, so the blend state is ONE / ONE_MINUS_SRC_ALPHA and
    // compositing stays associative however many instances overlap.
    float a = c.a * cov;
    out_color = vec4(c.rgb * a, a);
}
