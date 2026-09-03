in vec2 vUv;
out vec4 frag;

uniform sampler2D uState;
uniform sampler2D uAtlas;
uniform sampler2D uBrightnessBoost;
uniform vec2 uGrid;
uniform vec2 uAtlasGrid;
uniform vec3 uTail;
uniform vec3 uBody;
uniform vec3 uBright;
uniform vec3 uHead;
uniform float uGoldSparkle;
uniform float uLeadBrightness;
uniform float uColOffset;
uniform vec2 uOutputSize;
uniform vec2 uLogicalPerPixel;
uniform vec2 uVirtualOrigin;
uniform float uCellPixels;

const float goldSparkleBloom = 0.35;

float sampleGlyph(float glyph, vec2 cellUv, vec2 duvdx, vec2 duvdy) {
  float atlasX = mod(glyph, uAtlasGrid.x);
  float atlasY = floor(glyph / uAtlasGrid.x);
  vec2 uv = (vec2(atlasX, atlasY) + cellUv) / uAtlasGrid;
  return textureGrad(uAtlas, uv, duvdx, duvdy).r;
}

void main() {
  vec2 outputPixel = vec2(vUv.x * uOutputSize.x, (1.0 - vUv.y) * uOutputSize.y);
  vec2 logicalPixel = outputPixel * uLogicalPerPixel + uVirtualOrigin;
  vec2 cellCoordinate = logicalPixel / uCellPixels - vec2(uColOffset, 0.0);
  ivec2 cell = ivec2(floor(cellCoordinate));
  int columns = max(1, int(uGrid.x));
  cell.x = cell.x - int(floor(float(cell.x) / float(columns))) * columns;
  cell.y = clamp(cell.y, 0, max(0, int(uGrid.y) - 1));
  vec2 cellUv = fract(cellCoordinate);

  vec4 packedState = texelFetch(uState, cell, 0);
  float glyphNew = floor(packedState.r * 255.0 + 0.5);
  float bright = packedState.g + max(0.0, texelFetch(uBrightnessBoost, cell, 0).r);
  int flags = int(floor(packedState.b * 255.0 + 0.5));
  float glyphOld = floor(packedState.a * 255.0 + 0.5);
  bool isHead = (flags & 128) != 0;
  bool whiteHead = (flags & 64) != 0;
  float phase = float(flags & 63) / 63.0;

  vec2 duvdx = vec2(dFdx(cellCoordinate.x), dFdx(cellCoordinate.y)) / uAtlasGrid;
  vec2 duvdy = vec2(dFdy(cellCoordinate.x), dFdy(cellCoordinate.y)) / uAtlasGrid;
  float inkNew = sampleGlyph(glyphNew, cellUv, duvdx, duvdy);
  float ink = phase < 1.0
    ? mix(sampleGlyph(glyphOld, cellUv, duvdx, duvdy), inkNew, phase)
    : inkNew;

  vec3 color = mix(uTail, uBody, smoothstep(0.0, 0.5, bright));
  color = mix(color, uBright, smoothstep(0.55, 0.95, bright));
  color = mix(color, uHead, (whiteHead ? 1.0 : 0.0) * smoothstep(0.8, 1.0, bright));
  float sparklePulse = max(isHead ? 0.45 : 0.0, 4.0 * phase * (1.0 - phase));
  float goldSparkle = uGoldSparkle * sparklePulse * smoothstep(0.45, 0.95, bright);
  color = mix(color, uHead, goldSparkle);

  float baseIntensity = bright * ink;
  float headExtra = isHead ? (0.6 + (whiteHead ? uLeadBrightness : 0.0)) : 0.0;
  float displayIntensity = baseIntensity * (1.0 + headExtra + goldSparkle);
  frag = vec4(
    color * displayIntensity,
    baseIntensity * (headExtra + goldSparkle * goldSparkleBloom));
}
