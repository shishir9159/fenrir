// Shared between slug.vert and slug.frag.
//
// This is `src/gleipnir/slug.zig` transcribed, which is itself Eric Lengyel's
// Slug reference shaders (https://github.com/EricLengyel/Slug, MIT) with a
// numerically stable root solve and storage buffers in place of textures.
// Read the module comment there for what is computed and why.
//
// Every struct here is byte-identical to its `extern struct` on the Zig side.
// That is checked, not hoped: `lyngvi/shaders.zig` reads the offsets and
// strides back out of the compiled SPIR-V and compares them with `@offsetOf`.
// Keep every struct's members scalars or arrays of scalars wherever the Zig
// side is scalars -- a `vec4` member aligns the whole struct to sixteen under
// std430 and silently makes it longer than what was written.

struct Curve {
    vec2 p0;
    vec2 p1;
    vec2 p2;
};

struct Band {
    uint first;
    uint count;
};

struct PathHeader {
    float min_x;
    float min_y;
    float max_x;
    float max_y;
    uint curve_first;
    uint curve_count;
    uint band_first;   // horizontal bands, then vertical, back to back
    uint h_bands;
    uint v_bands;
    uint rule;         // 0 nonzero, 1 even-odd
};

// One drawn path or image. Byte-identical to `slugpipe.Instance`.
struct Instance {
    vec4  xform;       // a, b, c, d of path space -> device pixels
    vec2  translate;   // e, f of the same
    vec2  pad0;
    vec4  clip;        // device-space scissor: min x, min y, max x, max y
    vec4  color;       // premultiplied, linear light
    uint  header;      // index into headers[]
    uint  clip_node;   // index into clips[], or NO_CLIP
    uint  flags;       // composite in the low byte, FLAG_* above
    uint  image;       // index into images[], with FLAG_IMAGE
};

// A clip is a path plus a link to the clip enclosing it, so an arbitrarily
// nested clip stack is a list walk rather than an array copied per instance.
struct ClipNode {
    vec4 xform;
    vec2 translate;
    uint header;
    uint parent;       // NO_CLIP ends the chain
};

struct ImageInfo {
    uint offset;       // first texel
    uint width;
    uint height;
    uint pad;
};

layout(std430, set = 0, binding = 0) readonly buffer Curves    { Curve curves[]; };
layout(std430, set = 0, binding = 1) readonly buffer Bands     { Band bands[]; };
layout(std430, set = 0, binding = 2) readonly buffer Indices   { uint indices[]; };
layout(std430, set = 0, binding = 3) readonly buffer Headers   { PathHeader headers[]; };
layout(std430, set = 0, binding = 4) readonly buffer Instances { Instance instances[]; };
layout(std430, set = 0, binding = 5) readonly buffer Clips     { ClipNode clips[]; };
layout(std430, set = 0, binding = 6) readonly buffer Images    { ImageInfo images[]; };
layout(std430, set = 0, binding = 7) readonly buffer Texels    { uint texels[]; };

layout(push_constant) uniform Push {
    vec2 viewport;     // framebuffer size in pixels
} push;

const uint NO_CLIP = 0xffffffffu;

// How many clips deep the fragment shader will walk before giving up and
// drawing what it has. PDF clip stacks are one or two deep in practice; eight
// is where a pathological file stops costing more than it is worth.
const uint MAX_CLIP_WALK = 8u;

// Which roots of B(t) = 0 lie in [0, 1) and with what sign, for each of the
// eight sign patterns of the three relative y values. See `slug.root_table`.
const uint ROOT_TABLE = 0x2E74u;

const uint FLAG_IMAGE = 256u;
const uint FLAG_MASK = 512u;
const uint COMPOSITE_MASK = 255u;
const uint COMPOSITE_DARKEN = 3u;
const uint COMPOSITE_LIGHTEN = 4u;

float curveX(Curve c, float t) {
    float u = 1.0 - t;
    return u * u * c.p0.x + 2.0 * u * t * c.p1.x + t * t * c.p2.x;
}

// One curve's crossings with the ray from `p` towards +x: the coverage-
// weighted winding it adds in `.x`, and the weight of its nearest crossing
// in `.y`. `slug.crossingsTable`.
vec2 crossings(Curve c, vec2 p, float ppu) {
    float y0 = c.p0.y - p.y;
    float y1 = c.p1.y - p.y;
    float y2 = c.p2.y - p.y;

    uint shift = (y0 > 0.0 ? 2u : 0u) + (y1 > 0.0 ? 4u : 0u) + (y2 > 0.0 ? 8u : 0u);
    uint code = (ROOT_TABLE >> shift) & 3u;
    if (code == 0u) return vec2(0.0);

    float a = y0 - 2.0 * y1 + y2;
    float b = y0 - y1;

    // The table is an upper bound on the crossings, not a count of them: its
    // `3` cases only say the control point is on the far side, and a
    // quadratic does not pass through its control point.
    float disc = b * b - a * y0;
    if (disc < 0.0) return vec2(0.0);

    // The stable root pair: no epsilon, and exact as `a` goes to zero, which
    // every straight segment does. See `slug.roots`.
    float root = sqrt(disc);
    float s = b >= 0.0 ? b + root : b - root;
    if (s == 0.0) return vec2(0.0);
    float far = s / a;
    float near = y0 / s;
    float t0 = b >= 0.0 ? near : far;
    float t1 = b >= 0.0 ? far : near;

    vec2 out_ = vec2(0.0);
    if ((code & 1u) != 0u) {
        float r = (curveX(c, t0) - p.x) * ppu;
        out_.x -= clamp(r + 0.5, 0.0, 1.0);
        out_.y = max(out_.y, clamp(1.0 - abs(r) * 2.0, 0.0, 1.0));
    }
    if ((code & 2u) != 0u) {
        float r = (curveX(c, t1) - p.x) * ppu;
        out_.x += clamp(r + 0.5, 0.0, 1.0);
        out_.y = max(out_.y, clamp(1.0 - abs(r) * 2.0, 0.0, 1.0));
    }
    return out_;
}

Curve swapped(Curve c) {
    return Curve(c.p0.yx, c.p1.yx, c.p2.yx);
}

uint bandOf(float lo, float hi, float v, uint count) {
    float extent = hi - lo;
    if (!(extent > 0.0) || count == 0u) return 0u;
    float t = (v - lo) / extent * float(count);
    if (!(t > 0.0)) return 0u;
    return min(uint(t), count - 1u);
}

// The ray towards +x, over the horizontal band containing p.y.
vec2 rayAlongX(PathHeader h, vec2 p, float ppu) {
    Band band = bands[h.band_first + bandOf(h.min_y, h.max_y, p.y, h.h_bands)];
    vec2 acc = vec2(0.0);
    for (uint k = 0u; k < band.count; ++k) {
        Curve c = curves[indices[band.first + k]];
        // Sorted by reach, so the first curve behind the pixel ends the band.
        if ((max(max(c.p0.x, c.p1.x), c.p2.x) - p.x) * ppu < -0.5) break;
        vec2 r = crossings(c, p, ppu);
        acc.x += r.x;
        acc.y = max(acc.y, r.y);
    }
    return acc;
}

// The ray towards +y, over the vertical band containing p.x. The axes are
// exchanged, which reflects the outline and reverses its winding, so the
// sum is negated back.
vec2 rayAlongY(PathHeader h, vec2 p, float ppu) {
    Band band = bands[h.band_first + h.h_bands + bandOf(h.min_x, h.max_x, p.x, h.v_bands)];
    vec2 acc = vec2(0.0);
    for (uint k = 0u; k < band.count; ++k) {
        Curve c = curves[indices[band.first + k]];
        if ((max(max(c.p0.y, c.p1.y), c.p2.y) - p.y) * ppu < -0.5) break;
        vec2 r = crossings(swapped(c), p.yx, ppu);
        acc.x -= r.x;
        acc.y = max(acc.y, r.y);
    }
    return acc;
}

float applyRule(float winding, uint rule) {
    float w = abs(winding);
    if (rule == 0u) return min(w, 1.0);
    float m = mod(w, 2.0);
    return m <= 1.0 ? m : 2.0 - m;
}

// The fraction of the pixel at `p` that path `header` covers. `slug.coverageAt`.
//
// `ppu` is device pixels per path unit in each axis, from the inverse of the
// transform -- what `fwidth` of the path coordinate would give. `p` is the
// pixel's centre, in path space.
float pathCoverage(uint header, vec2 p, vec2 ppu) {
    PathHeader h = headers[header];
    if (h.curve_count == 0u || h.h_bands == 0u || !(ppu.x > 0.0) || !(ppu.y > 0.0)) return 0.0;

    vec2 half_ = 0.5 / ppu;
    if (p.x + half_.x < h.min_x || p.x - half_.x > h.max_x) return 0.0;
    if (p.y + half_.y < h.min_y || p.y - half_.y > h.max_y) return 0.0;

    vec2 xr = rayAlongX(h, p, ppu.x);
    vec2 yr = rayAlongY(h, p, ppu.y);

    float weighted = abs(xr.x * xr.y + yr.x * yr.y) / max(xr.y + yr.y, 1.0 / 65536.0);
    float cov = max(weighted, min(abs(xr.x), abs(yr.x)));
    return applyRule(cov, h.rule);
}

// Path space to device pixels, and back.
vec2 applyXform(vec4 m, vec2 t, vec2 p) {
    return vec2(m.x * p.x + m.z * p.y + t.x, m.y * p.x + m.w * p.y + t.y);
}

vec2 invertXform(vec4 m, vec2 t, vec2 p) {
    float det = m.x * m.w - m.y * m.z;
    if (det == 0.0) return vec2(0.0);
    float inv = 1.0 / det;
    vec2 d = p - t;
    return vec2((d.x * m.w - d.y * m.z) * inv, (d.y * m.x - d.x * m.y) * inv);
}

// Device pixels per path unit in each axis. `slug.Scale.of`.
vec2 pixelsPerUnit(vec4 m) {
    float det = abs(m.x * m.w - m.y * m.z);
    float across_x = abs(m.z) + abs(m.w);
    float across_y = abs(m.x) + abs(m.y);
    return vec2(across_x > 0.0 ? det / across_x : 0.0, across_y > 0.0 ? det / across_y : 0.0);
}

float srgbToLinear(float s) {
    return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4);
}

// How many samples to take across a device pixel that spans `footprint`
// texels. `raster.sampleSteps`.
uint sampleSteps(float footprint) {
    if (!(footprint > 1.5)) return 1u;
    return min(4u, uint(ceil(footprint)));
}
