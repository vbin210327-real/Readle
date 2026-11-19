#include <metal_stdlib>
using namespace metal;

static float gaussian(float value) {
    return exp(-0.5f * value * value);
}

// Illumination in the paywall moon's original coordinate space.
static float moonLight(float2 position) {
    const float2 center(178.4f, 221.6f);
    const float radius = 157.36f;
    float2 delta = position - center;
    float distance = length(delta);
    float altitude = distance - radius;
    float limbX = radius * delta.x / distance;

    // Sample illumination along the curved horizon. The peak of the atmosphere
    // sits slightly to the left of the specular crest.
    float atmosphere = 76.5f * gaussian((limbX + 75.85f) / 30.86f)
                             * gaussian(max(altitude, 0.0f) / 13.62f);
    float crestOffset = abs((limbX + 64.30f) / 33.03f);
    float crest = 190.7f * exp(-0.5f * crestOffset * crestOffset * crestOffset)
                         * exp(min(altitude, 0.0f) / 2.59f);
    float surface = 90.6f * gaussian((limbX + 74.47f) / 40.70f)
                          * exp(min(altitude, 0.0f) / 11.33f);
    float sky = 1.0f / (1.0f + exp(clamp((0.37f - altitude) / 0.315f, -40.0f, 40.0f)));
    float ambientSky = 8.44f * gaussian((position.x - 100.0f) / 41.0f);
    return mix(crest + surface, ambientSky + atmosphere, sky);
}

static half moonGray(float light, float2 position) {
    // A subpixel dither keeps the long shadow falloff smooth on dark displays.
    float grain = fract(52.9829189f * fract(dot(position * 3.0f, float2(0.06711056f, 0.00583715f))));
    return half(saturate((light + grain - 0.5f) / 255.0f));
}

// The patch is 202 × 160 points. Its right edge aligns with the header,
// and the comparison table crosses it 116 points from the top.
[[ stitchable ]] half4 paywallMoon(float2 position, half4 source) {
    half gray = moonGray(18.6f + moonLight(position), position);
    float2 edges = min(position, float2(202.0f, 160.0f) - position);
    half alpha = source.a * half(smoothstep(0.0f, 24.0f, min(edges.x, edges.y)));
    return half4(half3(gray) * alpha, alpha);
}

[[ stitchable ]] half4 membershipSurface(float2 position, half4 source, float4 bounds) {
    // Evaluate the moon, corner lighting and inset glow in one pass.
    float width = max(bounds.z, 1.0f);
    float2 patch = (position - bounds.xy) / width;
    float2 extent = bounds.zw / width;
    float2 uv = saturate((position - bounds.xy) / max(bounds.zw, float2(1.0f)));
    float2 sample = float2(-10.0f, 62.0f) + patch * 145.0f;
    half gray = moonGray(moonLight(sample), position);
    float moon = float(gray) * smoothstep(0.40f, 0.71f, patch.x)
                            * (1.0f - smoothstep(0.34f, 0.55f, patch.y));
    float corner = 0.18f * max(0.0f, 1.0f - length(patch) / 0.38f)
                 + 0.16f * max(0.0f, 1.0f - length(extent - patch) / 0.28f);

    const float radius = 0.067f;
    float2 q = abs(patch - extent / 2.0f) - (extent / 2.0f - radius);
    float distanceToRim = radius - length(max(q, 0.0f)) - min(max(q.x, q.y), 0.0f);
    float rim = 0.055f * (1.0f - smoothstep(0.0f, 0.048f, distanceToRim))
                         * (0.35f + 0.65f * abs(1.0f - uv.y - uv.x));
    float3 base(0.034f, 0.037f, 0.048f);
    float3 color = 1.0f - (1.0f - base) * (1.0f - moon) * (1.0f - corner) * (1.0f - rim);
    return half4(half3(color) * source.a, source.a);
}

// Neutral sRGB tones sampled from the paywall reference. Preserve the mask's
// fractional alpha at rounded and chamfered edges.
static half4 cardTone(float tone, float2 position, half alpha) {
    float dither = fract(52.9829189f * fract(dot(position * 3.0f, float2(0.06711056f, 0.00583715f)))) - 0.5f;
    return half4(half3(half((tone + dither) / 255.0f) * alpha), alpha);
}

[[ stitchable ]] half4 paywallGlass(float2 position, half4 source, float4 bounds, float headerHeight) {
    float2 uv = saturate((position - bounds.xy) / bounds.zw);
    float topLeft = 64.0f * exp(-uv.x / 0.37f - pow(uv.y / 0.415f, 1.6f));
    float topRight = 21.0f * uv.x * pow(1.0f - uv.y, 3.0f);
    float bottomRight = 71.0f * exp(-(1.0f - uv.x) / 0.44f - (1.0f - uv.y) / 0.19f);
    float header = position.y - bounds.y < headerHeight ? 19.0f : 0.0f;
    return cardTone(28.4f + topLeft + topRight + bottomRight + header, position, source.a);
}

[[ stitchable ]] half4 featuredPlanSurface(float2 position, half4 source, float4 bounds) {
    float2 uv = saturate((position - bounds.xy) / bounds.zw);
    float right = (1.0f - uv.x) / 0.27f;
    float left = (uv.x - 0.06f) / 0.325f;
    float topLight = 80.0f * exp(-right * right - uv.y / 0.23f);
    float bottomLight = 47.0f * exp(-left * left - (1.0f - uv.y) / 0.132f);
    return cardTone(31.0f + topLight + bottomLight, position, source.a);
}

[[ stitchable ]] half4 standardPlanSurface(float2 position, half4 source, float4 bounds, float lifetime) {
    float2 uv = saturate((position - bounds.xy) / bounds.zw);
    float top = 1.0f - uv.y;
    float wash = mix(9.2f, 6.2f, lifetime) * top;
    float left = exp(-uv.x / mix(0.30f, 0.20f, lifetime));
    float sheen = mix(7.5f, 12.8f, lifetime) * left * (1.0f - mix(0.63f, 0.31f, lifetime) * top);
    return cardTone(27.1f + wash + sheen, position, source.a);
}
