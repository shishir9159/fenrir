// The rect pipeline, in Slang: `rect.vert`, `rect.frag` and `rect.glsl` as one
// module with two entry points. A port of the GLSL, which is a
// transliteration of `src/gleipnir/sdf.zig`; the comments that explain the
// arithmetic live there and are not repeated here.
//
// `SV_VulkanInstanceID` and `SV_VulkanVertexID` rather than the D3D
// semantics, which subtract the draw's base: the renderer draws two ranges
// of one instance buffer with `firstInstance`, and needs the absolute index.

struct Instance {
    float4 dst;
    float4 src;
    float4 clip;
    float4 radius;
    uint4 color;
    float border;
    float softness;
    uint texture_id;
    uint flags;
};

[[vk::binding(0, 0)]] StructuredBuffer<Instance> instances;
[[vk::binding(1, 0)]] Texture2D textures[];
[[vk::binding(2, 0)]] SamplerState samp;

struct Push {
    float2 viewport;
};
[[vk::push_constant]] ConstantBuffer<Push> push;

static const uint FLAG_TEXTURED = 1;
static const uint FLAG_ALPHA_TEXTURE = 2;

struct VertexOut {
    float4 position : SV_Position;
    nointerpolation uint id : INSTANCE;
};

[shader("vertex")]
VertexOut vertexMain(uint vid : SV_VulkanVertexID, uint iid : SV_VulkanInstanceID) {
    Instance it = instances[iid];

    float pad = max(it.softness * 2.0, 1.0);
    float2 p0 = max(it.dst.xy - pad, it.clip.xy);
    float2 p1 = min(it.dst.zw + pad, it.clip.zw);
    p1 = max(p1, p0);

    float2 uv = float2(float(vid & 1u), float((vid >> 1) & 1u));
    float2 pos = lerp(p0, p1, uv);

    VertexOut o;
    o.id = iid;
    o.position = float4(pos / push.viewport * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

float sdRoundedBox(float2 p, float2 half_size, float4 r) {
    float rad = (p.y < 0.0) ? ((p.x < 0.0) ? r.x : r.y)
                            : ((p.x < 0.0) ? r.w : r.z);
    float2 q = abs(p) - half_size + rad;
    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0, 0.0))) - rad;
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

float srgbChannel(float s) {
    return s > 0.04045 ? pow((s + 0.055) / 1.055, 2.4) : s / 12.92;
}

float3 srgbToLinear(float3 s) {
    return float3(srgbChannel(s.r), srgbChannel(s.g), srgbChannel(s.b));
}

float4 corner(uint packed) {
    float4 c = float4(float(packed & 255u), float((packed >> 8) & 255u),
                      float((packed >> 16) & 255u), float((packed >> 24) & 255u)) / 255.0;
    return float4(srgbToLinear(c.rgb), c.a);
}

[shader("fragment")]
float4 fragmentMain(VertexOut v) : SV_Target {
    Instance it = instances[v.id];
    float2 p = v.position.xy;

    float2 center = (it.dst.xy + it.dst.zw) * 0.5;
    float2 half_size = (it.dst.zw - it.dst.xy) * 0.5;

    float d = sdRoundedBox(p - center, half_size, it.radius);
    d = ring(d, it.border);

    float cov = coverage(d, it.softness, fwidth(d));
    if (cov <= 0.0) discard;

    float2 t = clamp((p - it.dst.xy) / max(it.dst.zw - it.dst.xy, float2(1e-6, 1e-6)), 0.0, 1.0);
    float4 c = lerp(lerp(corner(it.color.x), corner(it.color.y), t.x),
                    lerp(corner(it.color.w), corner(it.color.z), t.x),
                    t.y);

    if ((it.flags & FLAG_TEXTURED) != 0u) {
        float2 uv = lerp(it.src.xy, it.src.zw, t);
        float4 s = textures[NonUniformResourceIndex(it.texture_id)].Sample(samp, uv);
        if ((it.flags & FLAG_ALPHA_TEXTURE) != 0u) {
            c.a *= s.r;
        } else {
            c.rgb *= srgbToLinear(s.rgb);
            c.a *= s.a;
        }
    }

    float a = c.a * cov;
    return float4(c.rgb * a, a);
}
