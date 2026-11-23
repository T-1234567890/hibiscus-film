#include <CoreImage/CoreImage.h>

extern "C" { namespace coreimage {

float4 filmAutomaticAccent(sample_t original, sample_t tinted, sample_t guide) {
    float3 rgb = unpremultiply(guide).rgb;
    float chroma = max(rgb.r, max(rgb.g, rgb.b)) - min(rgb.r, min(rgb.g, rgb.b));
    // An accent sampled from the scene should leave whites and grays alone.
    return mix(original, tinted, smoothstep(0.035f, 0.19f, chroma));
}

} }
