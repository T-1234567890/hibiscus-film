#include <CoreImage/CoreImage.h>

extern "C" { namespace coreimage {

float4 filmChromaticDrift(sample_t original, sample_t red, sample_t blue) {
    float3 shifted = float3(red.r, original.g, blue.b);
    const float3 luma = float3(0.2126f, 0.7152f, 0.0722f);
    // Direct channel sampling keeps flat areas intact. Hold most of the original
    // luminance at hard edges so the color separation doesn't obscure detail.
    float correction = dot(original.rgb - shifted, luma) * 0.78f;
    return float4(saturate(shifted + correction), original.a);
}

} }
