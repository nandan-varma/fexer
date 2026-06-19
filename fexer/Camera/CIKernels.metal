#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// ZebraFilter — highlights over/under-exposed pixels with animated diagonal stripes.
extern "C" float4 zebraStripes(coreimage::sample_t s, float overThreshold, float underThreshold,
                                float time, float stripeWidth, coreimage::destination dest) {
    float2 d = dest.coord();
    float luma = dot(s.rgb, float3(0.299f, 0.587f, 0.114f));
    bool isOver  = luma > overThreshold;
    bool isUnder = luma < underThreshold;
    if (isOver || isUnder) {
        float stripe = fmod(d.x + d.y + time, stripeWidth * 2.0f);
        float4 warningColor = isOver ? float4(1.0f, 0.0f, 0.0f, 1.0f)
                                     : float4(0.0f, 0.4f, 1.0f, 1.0f);
        float4 altColor = float4(0.0f, 0.0f, 0.0f, 1.0f);
        return stripe < stripeWidth ? warningColor : altColor;
    }
    return s;
}

// FalseColorFilter — maps luminance bands to diagnostic colors.
// Blue=crushed, cyan=shadows, green=lower mids, passthrough=midtones,
// yellow=upper mids, orange=near-clip, red=blown.
extern "C" float4 falseColor(coreimage::sample_t s) {
    float luma = dot(s.rgb, float3(0.2126f, 0.7152f, 0.0722f));
    if (luma < 0.04f) {
        return float4(0.0f, 0.0f, 0.7f, 1.0f);
    } else if (luma < 0.12f) {
        float t = (luma - 0.04f) / 0.08f;
        return mix(float4(0.0f, 0.0f, 0.7f, 1.0f), float4(0.0f, 0.6f, 0.85f, 1.0f), t);
    } else if (luma < 0.35f) {
        float t = (luma - 0.12f) / 0.23f;
        return mix(float4(0.0f, 0.6f, 0.85f, 1.0f), float4(0.0f, 0.75f, 0.0f, 1.0f), t);
    } else if (luma < 0.55f) {
        return s;
    } else if (luma < 0.72f) {
        float t = (luma - 0.55f) / 0.17f;
        return mix(s, float4(1.0f, 0.85f, 0.0f, 1.0f), t * 0.75f);
    } else if (luma < 0.88f) {
        float t = (luma - 0.72f) / 0.16f;
        return mix(float4(1.0f, 0.85f, 0.0f, 1.0f), float4(1.0f, 0.3f, 0.0f, 1.0f), t);
    } else {
        return float4(1.0f, 0.0f, 0.0f, 1.0f);
    }
}

// FocusPeakingFilter — Sobel edge detector composited over the source image.
// Uses a general CIKernel so it can sample the 3x3 neighbourhood.
extern "C" float4 focusPeaking(coreimage::sampler src, float threshold, float4 highlightColor) {
    float2 d = src.coord();
    float3 lumaWeights = float3(0.2126f, 0.7152f, 0.0722f);

    float l00 = dot(src.sample(src.transform(d + float2(-1.0f, -1.0f))).rgb, lumaWeights);
    float l10 = dot(src.sample(src.transform(d + float2( 0.0f, -1.0f))).rgb, lumaWeights);
    float l20 = dot(src.sample(src.transform(d + float2( 1.0f, -1.0f))).rgb, lumaWeights);
    float l01 = dot(src.sample(src.transform(d + float2(-1.0f,  0.0f))).rgb, lumaWeights);
    float l21 = dot(src.sample(src.transform(d + float2( 1.0f,  0.0f))).rgb, lumaWeights);
    float l02 = dot(src.sample(src.transform(d + float2(-1.0f,  1.0f))).rgb, lumaWeights);
    float l12 = dot(src.sample(src.transform(d + float2( 0.0f,  1.0f))).rgb, lumaWeights);
    float l22 = dot(src.sample(src.transform(d + float2( 1.0f,  1.0f))).rgb, lumaWeights);

    float gx = -l00 + l20 - 2.0f*l01 + 2.0f*l21 - l02 + l22;
    float gy = -l00 - 2.0f*l10 - l20 + l02 + 2.0f*l12 + l22;
    float mag = sqrt(gx*gx + gy*gy);

    float4 center = src.sample(src.transform(d));
    float alpha = smoothstep(threshold * 0.5f, threshold, mag) * highlightColor.a;
    return mix(center, float4(highlightColor.rgb, 1.0f), alpha);
}
