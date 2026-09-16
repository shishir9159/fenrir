// The analytic path pipeline, in Slang: `slug.vert`, `slug.frag` and
// `slug.glsl` as one module with two entry points.
//
// A line-for-line port of the GLSL, which is itself `src/gleipnir/slug.zig`
// transcribed; read the module comment there for what is computed and why.
// The same tests hold both to the same contract: `lyngvi/shaders.zig` reads
// every buffer's stride and member offsets back out of whichever SPIR-V the
// build embedded and compares them with the Zig structs, so a layout that
// Slang packs differently fails a test rather than a page.
//
// Two Slang-specific points, both about matching the GLSL bit for bit:
//
// * `SV_VulkanInstanceID` and not `SV_InstanceID`. The latter follows D3D
//   and starts at zero for every draw, subtracting `firstInstance`; this
//   pipeline draws runs of one buffer with `firstInstance` offsets, so it
//   needs Vulkan's `gl_InstanceIndex`, which the former is.
// * No `fmod` in `applyRule`: HLSL's truncates towards zero where GLSL's
//   `mod` floors. The winding is non-negative there so they would agree, but
//   the floor is written out so nobody has to know that.

struct Curve {
    float2 p0;
    float2 p1;
    float2 p2;
};

struct Band {
    uint first;
    uint count;
};

// Scalars, not a `float4`: see `slug.Header`.
struct PathHeader {
    float min_x;
    float min_y;
    float max_x;
    float max_y;
    uint curve_first;
    uint curve_count;
    uint band_first;
    uint h_bands;
    uint v_bands;
    uint rule;
};

struct Instance {
    float4 xform;
    float2 translate;
    float2 pad0;
    float4 clip;
    float4 color;
    uint header;
    uint clip_node;
    uint flags;
    uint image;
};

struct ClipNode {
    float4 xform;
    float2 translate;
    uint header;
    uint parent;
};

struct ImageInfo {
    uint offset;
    uint width;
    uint height;
    uint pad;
};

[[vk::binding(0, 0)]] StructuredBuffer<Curve> curves;
[[vk::binding(1, 0)]] StructuredBuffer<Band> bands;
[[vk::binding(2, 0)]] StructuredBuffer<uint> indices;
[[vk::binding(3, 0)]] StructuredBuffer<PathHeader> headers;
[[vk::binding(4, 0)]] StructuredBuffer<Instance> instances;
[[vk::binding(5, 0)]] StructuredBuffer<ClipNode> clips;
[[vk::binding(6, 0)]] StructuredBuffer<ImageInfo> images;
[[vk::binding(7, 0)]] StructuredBuffer<uint> texels;

struct Push {
    float2 viewport;
};
[[vk::push_constant]] ConstantBuffer<Push> push;

static const uint NO_CLIP = 0xffffffff;
static const uint MAX_CLIP_WALK = 8;
static const uint ROOT_TABLE = 0x2E74;
static const uint FLAG_IMAGE = 256;
static const uint FLAG_MASK = 512;
static const uint COMPOSITE_MASK = 255;
static const uint COMPOSITE_DARKEN = 3;

float curveX(Curve c, float t) {
    float u = 1.0 - t;
    return u * u * c.p0.x + 2.0 * u * t * c.p1.x + t * t * c.p2.x;
}

// `slug.crossingsTable`: winding in `.x`, weight of the nearest crossing in `.y`.
float2 crossings(Curve c, float2 p, float ppu) {
    float y0 = c.p0.y - p.y;
    float y1 = c.p1.y - p.y;
    float y2 = c.p2.y - p.y;

    uint shift = (y0 > 0.0 ? 2u : 0u) + (y1 > 0.0 ? 4u : 0u) + (y2 > 0.0 ? 8u : 0u);
    uint code = (ROOT_TABLE >> shift) & 3u;
    if (code == 0u) return float2(0.0, 0.0);

    float a = y0 - 2.0 * y1 + y2;
    float b = y0 - y1;
    float disc = b * b - a * y0;
    if (disc < 0.0) return float2(0.0, 0.0);

    float root = sqrt(disc);
    float s = b >= 0.0 ? b + root : b - root;
    if (s == 0.0) return float2(0.0, 0.0);
    float far_ = s / a;
    float near_ = y0 / s;
    float t0 = b >= 0.0 ? near_ : far_;
    float t1 = b >= 0.0 ? far_ : near_;

    float2 acc = float2(0.0, 0.0);
    if ((code & 1u) != 0u) {
        float r = (curveX(c, t0) - p.x) * ppu;
        acc.x -= clamp(r + 0.5, 0.0, 1.0);
        acc.y = max(acc.y, clamp(1.0 - abs(r) * 2.0, 0.0, 1.0));
    }
    if ((code & 2u) != 0u) {
        float r = (curveX(c, t1) - p.x) * ppu;
        acc.x += clamp(r + 0.5, 0.0, 1.0);
        acc.y = max(acc.y, clamp(1.0 - abs(r) * 2.0, 0.0, 1.0));
    }
    return acc;
}

Curve swapped(Curve c) {
    Curve out_;
    out_.p0 = c.p0.yx;
    out_.p1 = c.p1.yx;
    out_.p2 = c.p2.yx;
    return out_;
}

uint bandOf(float lo, float hi, float v, uint count) {
    float extent = hi - lo;
    if (!(extent > 0.0) || count == 0u) return 0u;
    float t = (v - lo) / extent * float(count);
    if (!(t > 0.0)) return 0u;
    return min(uint(t), count - 1u);
}

float2 rayAlongX(PathHeader h, float2 p, float ppu) {
    Band band = bands[h.band_first + bandOf(h.min_y, h.max_y, p.y, h.h_bands)];
    float2 acc = float2(0.0, 0.0);
    for (uint k = 0u; k < band.count; ++k) {
        Curve c = curves[indices[band.first + k]];
        if ((max(max(c.p0.x, c.p1.x), c.p2.x) - p.x) * ppu < -0.5) break;
        float2 r = crossings(c, p, ppu);
        acc.x += r.x;
        acc.y = max(acc.y, r.y);
    }
    return acc;
}

float2 rayAlongY(PathHeader h, float2 p, float ppu) {
    Band band = bands[h.band_first + h.h_bands + bandOf(h.min_x, h.max_x, p.x, h.v_bands)];
    float2 acc = float2(0.0, 0.0);
    for (uint k = 0u; k < band.count; ++k) {
        Curve c = curves[indices[band.first + k]];
        if ((max(max(c.p0.y, c.p1.y), c.p2.y) - p.y) * ppu < -0.5) break;
        float2 r = crossings(swapped(c), p.yx, ppu);
        acc.x -= r.x;
        acc.y = max(acc.y, r.y);
    }
    return acc;
}

float applyRule(float winding, uint rule) {
    float w = abs(winding);
    if (rule == 0u) return min(w, 1.0);
    float m = w - 2.0 * floor(w * 0.5);
    return m <= 1.0 ? m : 2.0 - m;
}

float pathCoverage(uint header, float2 p, float2 ppu) {
    PathHeader h = headers[header];
    if (h.curve_count == 0u || h.h_bands == 0u || !(ppu.x > 0.0) || !(ppu.y > 0.0)) return 0.0;

    float2 half_ = 0.5 / ppu;
    if (p.x + half_.x < h.min_x || p.x - half_.x > h.max_x) return 0.0;
    if (p.y + half_.y < h.min_y || p.y - half_.y > h.max_y) return 0.0;

    float2 xr = rayAlongX(h, p, ppu.x);
    float2 yr = rayAlongY(h, p, ppu.y);

    float weighted = abs(xr.x * xr.y + yr.x * yr.y) / max(xr.y + yr.y, 1.0 / 65536.0);
    float cov = max(weighted, min(abs(xr.x), abs(yr.x)));
    return applyRule(cov, h.rule);
}

float2 applyXform(float4 m, float2 t, float2 p) {
    return float2(m.x * p.x + m.z * p.y + t.x, m.y * p.x + m.w * p.y + t.y);
}

float2 invertXform(float4 m, float2 t, float2 p) {
    float det = m.x * m.w - m.y * m.z;
    if (det == 0.0) return float2(0.0, 0.0);
    float inv = 1.0 / det;
    float2 d = p - t;
    return float2((d.x * m.w - d.y * m.z) * inv, (d.y * m.x - d.x * m.y) * inv);
}

float2 pixelsPerUnit(float4 m) {
    float det = abs(m.x * m.w - m.y * m.z);
    float across_x = abs(m.z) + abs(m.w);
    float across_y = abs(m.x) + abs(m.y);
    return float2(across_x > 0.0 ? det / across_x : 0.0, across_y > 0.0 ? det / across_y : 0.0);
}

float srgbToLinear(float s) {
    return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4);
}

uint sampleSteps(float footprint) {
    if (!(footprint > 1.5)) return 1u;
    return min(4u, uint(ceil(footprint)));
}

// GLSL's `unpackUnorm4x8`: red from the low byte.
float4 unpackTexel(uint t) {
    return float4(float(t & 255u), float((t >> 8) & 255u), float((t >> 16) & 255u), float((t >> 24) & 255u)) / 255.0;
}

float4 sampleImage(Instance it, float2 device) {
    ImageInfo info = images[it.image];
    if (info.width == 0u || info.height == 0u) return float4(0.0, 0.0, 0.0, 0.0);

    float4 m = it.xform;
    float det = m.x * m.w - m.y * m.z;
    if (det == 0.0) return float4(0.0, 0.0, 0.0, 0.0);
    float fx = (abs(m.w) + abs(m.z)) / abs(det);
    float fy = (abs(m.y) + abs(m.x)) / abs(det);
    uint sx_n = sampleSteps(fx * float(info.width));
    uint sy_n = sampleSteps(fy * float(info.height));

    float4 acc = float4(0.0, 0.0, 0.0, 0.0);
    float2 corner = device - 0.5;
    for (uint sy = 0u; sy < sy_n; ++sy) {
        for (uint sx = 0u; sx < sx_n; ++sx) {
            float2 at = corner + (float2(float(sx), float(sy)) + 0.5) / float2(float(sx_n), float(sy_n));
            float2 uv = invertXform(it.xform, it.translate, at);
            if (uv.x < 0.0 || uv.x >= 1.0 || uv.y < 0.0 || uv.y >= 1.0) continue;
            uint ix = min(info.width - 1u, uint(uv.x * float(info.width)));
            uint iy = min(info.height - 1u, uint((1.0 - uv.y) * float(info.height)));
            float4 t = unpackTexel(texels[info.offset + iy * info.width + ix]);
            acc += float4(t.rgb * t.a, t.a);
        }
    }
    float n = float(sx_n * sy_n);
    float cover = acc.a / n;
    if (cover <= 0.0) return float4(0.0, 0.0, 0.0, 0.0);

    if ((it.flags & FLAG_MASK) != 0u) return it.color * cover;

    float3 srgb = acc.rgb / acc.a;
    float a = cover * it.color.a;
    return float4(srgbToLinear(srgb.r) * a, srgbToLinear(srgb.g) * a, srgbToLinear(srgb.b) * a, a);
}

struct VertexOut {
    float4 position : SV_Position;
    nointerpolation uint id : INSTANCE;
};

[shader("vertex")]
VertexOut vertexMain(uint vid : SV_VulkanVertexID, uint iid : SV_VulkanInstanceID) {
    Instance it = instances[iid];

    float2 lo_p = float2(0.0, 0.0);
    float2 hi_p = float2(1.0, 1.0);
    if ((it.flags & FLAG_IMAGE) == 0u) {
        PathHeader h = headers[it.header];
        lo_p = float2(h.min_x, h.min_y);
        hi_p = float2(h.max_x, h.max_y);
    }

    float2 c0 = applyXform(it.xform, it.translate, lo_p);
    float2 c1 = applyXform(it.xform, it.translate, float2(hi_p.x, lo_p.y));
    float2 c2 = applyXform(it.xform, it.translate, hi_p);
    float2 c3 = applyXform(it.xform, it.translate, float2(lo_p.x, hi_p.y));

    float2 lo = min(min(c0, c1), min(c2, c3)) - 1.0;
    float2 hi = max(max(c0, c1), max(c2, c3)) + 1.0;

    float2 p0 = max(lo, it.clip.xy);
    float2 p1 = max(min(hi, it.clip.zw), p0);

    float2 uv = float2(float(vid & 1u), float((vid >> 1) & 1u));
    float2 pos = lerp(p0, p1, uv);

    VertexOut o;
    o.id = iid;
    o.position = float4(pos / push.viewport * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

[shader("fragment")]
float4 fragmentMain(VertexOut v) : SV_Target {
    Instance it = instances[v.id];
    float2 device = v.position.xy;

    float4 color;
    if ((it.flags & FLAG_IMAGE) != 0u) {
        color = sampleImage(it, device);
        if (color.a <= 0.0) discard;
    } else {
        float2 p = invertXform(it.xform, it.translate, device);
        float cov = pathCoverage(it.header, p, pixelsPerUnit(it.xform));
        if (cov <= 0.0) discard;
        color = it.color * cov;
    }

    uint node = it.clip_node;
    for (uint i = 0u; i < MAX_CLIP_WALK && node != NO_CLIP; ++i) {
        ClipNode c = clips[node];
        float2 cp = invertXform(c.xform, c.translate, device);
        color *= pathCoverage(c.header, cp, pixelsPerUnit(c.xform));
        if (color.a <= 0.0) discard;
        node = c.parent;
    }

    if ((it.flags & COMPOSITE_MASK) == COMPOSITE_DARKEN) {
        color = float4(color.rgb + (1.0 - color.a), 1.0);
    }
    return color;
}
