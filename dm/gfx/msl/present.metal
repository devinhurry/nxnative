// The present: the frame drawn into the drawable, cropped (nvn_mtl.m present_pipeline)
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
struct Crop { float4 rect; float4 edge; };
fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) { return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)); }

// This entry point is used only for final presentation, never texture copies
// or premultiplied UI composition. Modes match present_filter.h. Input is the
// same display-encoded SDR colour as fs; no second sRGB decode/encode is added.
struct FilterCrop { Crop crop; float4 effect; };
fragment float4 fs_filter(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant FilterCrop& c [[buffer(0)]]) {
    float4 color = t.sample(s, clamp(in.uv * c.crop.rect.zw + c.crop.rect.xy, c.crop.edge.xy, c.crop.edge.zw));
    float3 rgb = color.rgb, graded = rgb;
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    switch (uint(c.effect.x)) {
        case 1: graded = (mix(float3(luma), rgb, 1.20) - 0.5) * 1.08 + 0.5; break;
        case 3: graded += float3(0.055, 0.012, -0.045) * (4.0 * rgb * (1.0 - rgb)); break;
        case 4: graded += float3(-0.045, 0.008, 0.060) * (4.0 * rgb * (1.0 - rgb)); break;
    }
    return float4(mix(rgb, clamp(graded, 0.0, 1.0), c.effect.y), color.a);
}

// CUBE ordering is R fastest, then G, then B. Half-texel coordinates keep
// endpoints exact; hardware trilinear sampling interpolates all three axes.
struct LUTCrop { FilterCrop filter; float4 minimum; float4 scale; };
fragment float4 fs_lut(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture3d<float> lut [[texture(1)]],
                      sampler s [[sampler(0)]], constant LUTCrop& c [[buffer(0)]]) {
    float4 color = t.sample(s, clamp(in.uv * c.filter.crop.rect.zw + c.filter.crop.rect.xy, c.filter.crop.edge.xy, c.filter.crop.edge.zw));
    float edge = float(lut.get_width());
    float3 coordinate = clamp((color.rgb - c.minimum.xyz) * c.scale.xyz, 0.0, 1.0);
    float3 graded = lut.sample(s, (coordinate * (edge - 1.0) + 0.5) / edge).rgb;
    return float4(mix(color.rgb, clamp(graded, 0.0, 1.0), c.filter.effect.y), color.a);
}
