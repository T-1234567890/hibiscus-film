#include <CoreImage/CoreImage.h>

extern "C" { namespace coreimage {

static inline float inkLuma(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

float4 filmASCII(sampler photograph, sampler cells, sampler glyphs, float2 pitch,
                 float2 gridSize, float2 glyphSize, float glyphCount, float cutoff,
                 float adaptive, float4 darkInk, float4 lightInk, destination dest) {
    float2 position = dest.coord();
    float4 original = photograph.sample(photograph.transform(position));
    float2 cell = floor(position / pitch);
    float2 center = cell + 0.5f;
    float3 local = cells.sample(cells.transform(center)).rgb;
    float luma = inkLuma(local);
    float right = inkLuma(cells.sample(cells.transform(min(center + float2(1,0), gridSize - 0.5f))).rgb);
    float above = inkLuma(cells.sample(cells.transform(min(center + float2(0,1), gridSize - 0.5f))).rgb);
    float edge = saturate(3.0f * (abs(luma - right) + abs(luma - above)));

    // Map shadows and edges to the heavier symbols in the fixed glyph ramp.
    // Raising fill lowers the cutoff smoothly so new marks follow the subject.
    float density = saturate(0.92f * (1.0f - luma) + 0.27f * edge);
    float coverage = density - cutoff;
    if (coverage <= 0.055f) return original;

    float weight = saturate((coverage - 0.055f) / 0.86f);
    float index = floor(weight * (glyphCount - 1.0f) + 0.5f);
    float2 uv = clamp(fract(position / pitch) * glyphSize, 0.5f, glyphSize - 0.5f);
    float mark = glyphs.sample(glyphs.transform(uv + float2(index * glyphSize.x, 0))).r;

    float3 ink = abs(inkLuma(darkInk.rgb) - luma) > abs(inkLuma(lightInk.rgb) - luma) ? darkInk.rgb : lightInk.rgb;
    if (adaptive > 0.5f) {
        // Retain the local hue, lifting dark inks or shading light ones for legibility.
        ink = luma > 0.49f ? local * 0.32f : mix(local, float3(1), 0.52f);
    }
    return float4(mix(original.rgb, ink, mark), original.a);
}

} }
