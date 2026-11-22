#include <CoreImage/CoreImage.h>

extern "C" { namespace coreimage {

static inline float3 highlightLight(float4 pixel) {
    float3 rgb = max(unpremultiply(pixel).rgb, 0.0f);
    float luminance = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
    // Bound the radiated light from HDR sources while retaining their hue.
    return rgb * (smoothstep(0.50f, 0.88f, luminance) / max(1.0f, luminance)) * pixel.a;
}

float4 filmHighlightSeed(sample_t pixel) {
    return float4(highlightLight(pixel), 1.0f);
}

float4 filmHighlightComposite(sample_t pixel, sample_t scatter, float gain) {
    // Only incoming light lifts the image. Uniform highlights and sharp cores stay intact.
    float3 incoming = max(scatter.rgb - highlightLight(pixel), 0.0f);
    float3 headroom = 1.0f - saturate(unpremultiply(pixel).rgb);
    return float4(pixel.rgb + gain * incoming * headroom * pixel.a, pixel.a);
}

} }
