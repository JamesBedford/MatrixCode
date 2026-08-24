Texture2D<float4> texture0 : register(t0);
Texture2D<float4> texture1 : register(t1);
Texture2D<float4> texture2 : register(t2);
Texture2D<float4> texture3 : register(t3);
SamplerState pointSampler : register(s0);
SamplerState linearSampler : register(s1);

cbuffer GlyphConstants : register(b0) {
  float2 sceneSize;
  float2 virtualOrigin;
  float2 logicalPerPixel;
  float2 gridSize;
  float cellPixels;
  float laneOffset;
  float laneWeight;
  float leadBrightness;
  float goldSparkle;
  float elapsedSeconds;
  float2 _padGlyphAlignment;
  float3 backgroundColor;
  float _pad0;
  float3 tailColor;
  float _pad1;
  float3 bodyColor;
  float _pad2;
  float3 brightColor;
  float _pad3;
  float3 headColor;
  float _pad4;
};

cbuffer PostConstants : register(b1) {
  float2 sourceTexel;
  float2 outputSize;
  float glow;
  float vignette;
  float scanlines;
  float bloomLevels;
  float3 postBackground;
  float _padPost;
};

cbuffer OverlayConstants : register(b2) {
  float2 overlayOrigin;
  float2 overlaySize;
  float overlayOpacity;
  float3 overlayPadding;
};

struct FullscreenOutput {
  float4 position : SV_Position;
  float2 uv : TEXCOORD0;
};

FullscreenOutput FullscreenVs(uint id : SV_VertexID) {
  FullscreenOutput output;
  output.uv = float2((id << 1) & 2, id & 2);
  output.position = float4(output.uv * float2(2, -2) + float2(-1, 1), 0, 1);
  return output;
}

float4 GlyphPs(FullscreenOutput input) : SV_Target {
  float2 logicalPixel = input.position.xy / sceneSize * outputSize * logicalPerPixel + virtualOrigin;
  float2 cellCoordinate = logicalPixel / cellPixels - float2(laneOffset, 0);
  int2 cell = int2(floor(cellCoordinate));
  float2 withinCell = frac(cellCoordinate);
  int gridColumns = int(gridSize.x);
  cell.y = clamp(cell.y, 0, int(gridSize.y) - 1);
  cell.x -= int(floor(float(cell.x) / float(gridColumns))) * gridColumns;
  float4 packed = texture0.Load(int3(cell, 0));
  uint newGlyph = (uint)round(packed.r * 255.0);
  uint brightnessByte = (uint)round(packed.g * 255.0);
  uint flags = (uint)round(packed.b * 255.0);
  uint oldGlyph = (uint)round(packed.a * 255.0);
  float brightness = brightnessByte / 255.0 + max(0.0, texture2.Load(int3(cell, 0)).r);
  float phase = (flags & 63) / 63.0;
  bool isHead = (flags & 128) != 0;
  bool whiteHead = (flags & 64) != 0;
  const float atlasColumns = 14.0;
  const float atlasRows = 13.0;
  const float2 atlasGrid = float2(atlasColumns, atlasRows);
  float2 newTile = float2(newGlyph % 14, newGlyph / 14);
  float2 oldTile = float2(oldGlyph % 14, oldGlyph / 14);
  // Derive the mip LOD from the continuous cell coordinate. Using the
  // discontinuous withinCell value here makes the derivatives spike at each
  // frac() seam, selecting a coarse, cell-averaged mip that bloom exposes as
  // a bright rectangular outline around intense glyphs.
  float2 atlasDdx = ddx(cellCoordinate) / atlasGrid;
  float2 atlasDdy = ddy(cellCoordinate) / atlasGrid;
  float newCoverage = texture1.SampleGrad(
    linearSampler, (newTile + withinCell) / atlasGrid, atlasDdx, atlasDdy).a;
  float oldCoverage = texture1.SampleGrad(
    linearSampler, (oldTile + withinCell) / atlasGrid, atlasDdx, atlasDdy).a;
  float coverage = lerp(oldCoverage, newCoverage, phase);
  float sparklePulse = max(isHead ? 0.45 : 0.0, 4.0 * phase * (1.0 - phase));
  float sparkle = goldSparkle * sparklePulse * smoothstep(0.45, 0.95, brightness);
  float3 color = lerp(tailColor, bodyColor, smoothstep(0.0, 0.5, brightness));
  color = lerp(color, brightColor, smoothstep(0.55, 0.95, brightness));
  color = lerp(color, headColor, (whiteHead ? 1.0 : 0.0) * smoothstep(0.8, 1.0, brightness));
  color = lerp(color, headColor, sparkle);
  float baseIntensity = brightness * coverage;
  float headExtra = isHead ? (0.6 + (whiteHead ? leadBrightness : 0.0)) : 0.0;
  float displayIntensity = baseIntensity * (1.0 + headExtra + sparkle);
  return float4(
    color * displayIntensity,
    baseIntensity * (headExtra + sparkle * 0.35));
}

float4 OverlayPs(FullscreenOutput input) : SV_Target {
  float2 relative = input.position.xy - overlayOrigin;
  if (relative.x < 0 || relative.y < 0 || relative.x >= overlaySize.x ||
      relative.y >= overlaySize.y) return 0;
  return texture0.Sample(linearSampler, relative / overlaySize) * overlayOpacity;
}

float4 CopyPs(FullscreenOutput input) : SV_Target {
  return texture0.Sample(linearSampler, input.uv);
}

float4 BrightPassPs(FullscreenOutput input) : SV_Target {
  float4 scene = texture0.Sample(linearSampler, input.uv);
  float3 color = scene.rgb * smoothstep(0.0, 0.15, scene.a);
  float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
  color *= 1.0 / (1.0 + luma);
  return float4(color, 1.0);
}

float4 BlurHPs(FullscreenOutput input) : SV_Target {
  const float w0 = 0.2270270270;
  const float w12 = 0.3162162162;
  const float w34 = 0.0702702703;
  const float o12 = 1.3846153846;
  const float o34 = 3.2307692308;
  const float spread = 1.8;
  float2 axis = float2(sourceTexel.x * spread, 0);
  float4 color = texture0.Sample(linearSampler, input.uv) * w0;
  color += texture0.Sample(linearSampler, input.uv + axis * o12) * w12;
  color += texture0.Sample(linearSampler, input.uv - axis * o12) * w12;
  color += texture0.Sample(linearSampler, input.uv + axis * o34) * w34;
  color += texture0.Sample(linearSampler, input.uv - axis * o34) * w34;
  return color;
}

float4 BlurVPs(FullscreenOutput input) : SV_Target {
  const float w0 = 0.2270270270;
  const float w12 = 0.3162162162;
  const float w34 = 0.0702702703;
  const float o12 = 1.3846153846;
  const float o34 = 3.2307692308;
  const float spread = 1.8;
  float2 axis = float2(0, sourceTexel.y * spread);
  float4 color = texture0.Sample(linearSampler, input.uv) * w0;
  color += texture0.Sample(linearSampler, input.uv + axis * o12) * w12;
  color += texture0.Sample(linearSampler, input.uv - axis * o12) * w12;
  color += texture0.Sample(linearSampler, input.uv + axis * o34) * w34;
  color += texture0.Sample(linearSampler, input.uv - axis * o34) * w34;
  return color;
}

float3 aces(float3 x) {
  const float a = 2.51;
  const float b = 0.03;
  const float c = 2.43;
  const float d = 0.59;
  const float e = 0.14;
  return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

float4 CompositePs(FullscreenOutput input) : SV_Target {
  float3 bloom = bloomLevels > 0.5
    ? texture1.Sample(linearSampler, input.uv).rgb
    : 0.0;
  float3 color = aces(texture0.Sample(linearSampler, input.uv).rgb + glow * bloom);
  color = max(color, postBackground);
  if (scanlines > 0.0) {
    float lines = 0.5 + 0.5 * sin((1.0 - input.uv.y) * outputSize.y * 1.5);
    color *= 1.0 - scanlines * (1.0 - lines);
  }
  if (vignette > 0.0) {
    float distanceFromCenter = length((input.uv - 0.5) / float2(0.42, 0.42));
    float value = 1.0 - smoothstep(0.15, 0.95, distanceFromCenter);
    color *= lerp(1.0, pow(saturate(value), 2.8), vignette);
  }
  return float4(color, 1.0);
}
