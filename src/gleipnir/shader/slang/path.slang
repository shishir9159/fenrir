// The stencil-then-cover path pipeline, in Slang: `path.vert`, `path.frag`
// and `path.glsl` as one module. See the GLSL for why it is this small.
//
// The push constant is a `ConstantBuffer` marked `vk::push_constant`; its
// two `float4`s and two `float2`s lay out the same under std140 and std430,
// forty bytes, which is `pathpipe.PushConstants`.

struct Push {
    float4 xform;
    float4 color;
    float2 translate;
    float2 viewport;
};
[[vk::push_constant]] ConstantBuffer<Push> push;

float2 pathToDevice(float2 p) {
    return float2(push.xform.x * p.x + push.xform.z * p.y + push.translate.x,
                  push.xform.y * p.x + push.xform.w * p.y + push.translate.y);
}

[shader("vertex")]
float4 vertexMain(float2 in_pos : POSITION) : SV_Position {
    float2 p = pathToDevice(in_pos);
    return float4(p / push.viewport * 2.0 - 1.0, 0.0, 1.0);
}

[shader("fragment")]
float4 fragmentMain() : SV_Target {
    return push.color;
}
