#version 450
#extension GL_GOOGLE_include_directive : require
#include "slug.glsl"

layout(location = 0) flat in uint v_id;
layout(location = 0) out vec4 out_color;

// An image over the unit square, sampled the way `raster.Canvas.drawImage`
// samples it: up to four by four points across the device pixel, each
// mapped back into the image and taken from the nearest texel, averaged
// premultiplied, and divided by the whole count so the edge of the image is
// its antialiased edge. Returns premultiplied, linear light.
vec4 sampleImage(Instance it, vec2 device) {
    ImageInfo info = images[it.image];
    if (info.width == 0u || info.height == 0u) return vec4(0.0);

    vec4 m = it.xform;
    float det = m.x * m.w - m.y * m.z;
    if (det == 0.0) return vec4(0.0);
    // The inverse's rows, for the footprint: how much of the unit square one
    // pixel step spans, in each axis.
    float fx = (abs(m.w) + abs(m.z)) / abs(det);
    float fy = (abs(m.y) + abs(m.x)) / abs(det);
    uint sx_n = sampleSteps(fx * float(info.width));
    uint sy_n = sampleSteps(fy * float(info.height));

    vec4 acc = vec4(0.0);
    vec2 corner = device - 0.5;
    for (uint sy = 0u; sy < sy_n; ++sy) {
        for (uint sx = 0u; sx < sx_n; ++sx) {
            vec2 at = corner + (vec2(float(sx), float(sy)) + 0.5) / vec2(float(sx_n), float(sy_n));
            vec2 uv = invertXform(it.xform, it.translate, at);
            if (uv.x < 0.0 || uv.x >= 1.0 || uv.y < 0.0 || uv.y >= 1.0) continue;
            // Row zero is the top of the image and v = 1 is the top of the
            // unit square.
            uint ix = min(info.width - 1u, uint(uv.x * float(info.width)));
            uint iy = min(info.height - 1u, uint((1.0 - uv.y) * float(info.height)));
            vec4 t = unpackUnorm4x8(texels[info.offset + iy * info.width + ix]);
            acc += vec4(t.rgb * t.a, t.a);
        }
    }
    float n = float(sx_n * sy_n);
    float cover = acc.a / n;
    if (cover <= 0.0) return vec4(0.0);

    if ((it.flags & FLAG_MASK) != 0u) {
        // A stencil: the alpha is where to paint, the instance is the paint.
        return it.color * cover;
    }
    // Averaged in sRGB, as the CPU sampler averages, then into light.
    vec3 srgb = acc.rgb / acc.a;
    float a = cover * it.color.a;
    return vec4(
        srgbToLinear(srgb.r) * a,
        srgbToLinear(srgb.g) * a,
        srgbToLinear(srgb.b) * a,
        a
    );
}

void main() {
    Instance it = instances[v_id];
    vec2 device = gl_FragCoord.xy;

    vec4 color;
    if ((it.flags & FLAG_IMAGE) != 0u) {
        color = sampleImage(it, device);
        if (color.a <= 0.0) discard;
    } else {
        // The pixel's centre, taken back into the space the curves are in.
        vec2 p = invertXform(it.xform, it.translate, device);
        float cov = pathCoverage(it.header, p, pixelsPerUnit(it.xform));
        if (cov <= 0.0) discard;
        color = it.color * cov;
    }

    // Clipping, analytically, in the same pass.
    //
    // This is where the design pays for itself. Stencil-and-cover has no
    // answer to an antialiased clip -- a stencil bit is in or out, so a
    // clipped edge is either jagged or needs a second attachment and a
    // resolve. Here a clip is just another path, its coverage is computed by
    // the same function, and intersecting two clips is multiplying two
    // numbers. The clip stack is a linked list walked from the innermost
    // outwards, so nesting costs a loop iteration rather than a buffer.
    uint node = it.clip_node;
    for (uint i = 0u; i < MAX_CLIP_WALK && node != NO_CLIP; ++i) {
        ClipNode c = clips[node];
        vec2 cp = invertXform(c.xform, c.translate, device);
        color *= pathCoverage(c.header, cp, pixelsPerUnit(c.xform));
        if (color.a <= 0.0) discard;
        node = c.parent;
    }

    // MIN and MAX ignore the blend factors, so the partial coverage an edge
    // needs is folded in here instead: composited over each operator's
    // identity -- white for darken, black for lighten -- a half-covered pixel
    // moves the backdrop halfway. `slugpipe.Composite`.
    uint composite = it.flags & COMPOSITE_MASK;
    if (composite == COMPOSITE_DARKEN) {
        color = vec4(color.rgb + (1.0 - color.a), 1.0);
    }

    // Premultiplied, linear light, to match the rect pipeline's blend state:
    // ONE / ONE_MINUS_SRC_ALPHA over an _SRGB attachment.
    out_color = color;
}
