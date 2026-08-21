#version 300 es
precision highp float;

// Glyph pass: map each pixel to a grid cell, read the cell's packed state, sample
// the glyph atlas (old + new, crossfaded), and output the green ramp.
//   frag.rgb = on-screen color * display intensity (may exceed 1 in HDR mode)
//   frag.a   = bloom mask for heads and the gold theme's brief mutation glints.

in vec2 vUv;
out vec4 frag;

uniform sampler2D uState; // cols x rows, RGBA8 (NEAREST)
uniform sampler2D uAtlas; // glyph atlas, R8 coverage (LINEAR + mips)
uniform vec2 uGrid;       // (cols, rows)
uniform vec2 uAtlasGrid;  // (atlasCols, atlasRows)
uniform vec3 uTail;
uniform vec3 uBody;
uniform vec3 uBright;
uniform vec3 uHead;
uniform float uGoldSparkle;
uniform float uLeadBrightness; // extra HDR for white-hot heads
uniform float uColOffset;      // horizontal shift in cells; base layer = 0.0, overlap layers land between columns
uniform vec2 uViewport;        // viewport size in CSS pixels
uniform vec2 uCell;            // shared cell size in CSS pixels
uniform vec2 uGridOrigin;      // local position of cell (0,0), possibly negative at a monitor seam
uniform int uImageEnabled;
uniform sampler2D uImageMask;  // active portable R8 luminance mask (NEAREST; bilinear is explicit below)
uniform vec2 uImageMaskSize;
uniform vec4 uImageRect;       // origin column/row, width/height in the full virtual grid
uniform vec2 uImageFeather;
uniform float uImageIntensity;
uniform float uImageScramble;
uniform uint uImageSeed;
uniform float uImageRainElapsed;
uniform uint uImageAnimationBucket;
uniform vec2 uGlobalCellOffset;
uniform int uGlyphMode;        // matrix, katakana, binary, digits, latin, symbols = 0..5
uniform vec4 uRainRanges;      // digit start, latin start, symbol start, message start

const float goldSparkleBloom = 0.35;

// Gradients of the atlas UV taken from the *continuous* cell coordinate, so the
// fract() seam between cells doesn't blow up the implicit LOD (which would force
// the coarsest mip and draw a bright box outline around bloomed heads).
float sampleGlyph(float gi, vec2 cellUv, vec2 duvdx, vec2 duvdy) {
  float ax = mod(gi, uAtlasGrid.x);
  float ay = floor(gi / uAtlasGrid.x);
  vec2 uv = (vec2(ax, ay) + cellUv) / uAtlasGrid;
  return textureGrad(uAtlas, uv, duvdx, duvdy).r; // R8 coverage atlas
}

uint imageHash(uint value) {
  value ^= value >> 16;
  value *= 0x7feb352du;
  value ^= value >> 15;
  value *= 0x846ca68bu;
  return value ^ (value >> 16);
}

float imageUnit(uint value) {
  return float(imageHash(value) & 0x00ffffffu) / 16777216.0;
}

float sampleImageMask(vec2 uv) {
  vec2 p = clamp(uv, 0.0, 1.0) * max(vec2(0.0), uImageMaskSize - 1.0);
  ivec2 p0 = ivec2(floor(p));
  ivec2 p1 = min(ivec2(uImageMaskSize) - 1, p0 + 1);
  vec2 t = fract(p);
  float a = texelFetch(uImageMask, p0, 0).r;
  float b = texelFetch(uImageMask, ivec2(p1.x, p0.y), 0).r;
  float c = texelFetch(uImageMask, ivec2(p0.x, p1.y), 0).r;
  float d = texelFetch(uImageMask, p1, 0).r;
  return mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
}

float imageSignal(float luminance) {
  float value = clamp(luminance, 0.0, 1.0);
  float nonEmpty = smoothstep(0.035, 0.12, value);
  float contrastSignal = abs(value - 0.5) * 2.0 * nonEmpty;
  float brightSignal = value * 0.72;
  return max(contrastSignal, brightSignal) * nonEmpty;
}

float imageEdgeFeather(vec2 uv) {
  float horizontal = min(
    smoothstep(0.0, uImageFeather.x, uv.x),
    smoothstep(0.0, uImageFeather.x, 1.0 - uv.x));
  float vertical = min(
    smoothstep(0.0, uImageFeather.y, uv.y),
    smoothstep(0.0, uImageFeather.y, 1.0 - uv.y));
  return horizontal * vertical;
}

float imageFallingGate(ivec2 globalCell) {
  uint columnKey = uImageSeed ^ uint(globalCell.x) * 0x9e3779b9u ^ 0x748f4a15u;
  float speed = 4.5 + imageUnit(columnKey ^ 0x85ebca6bu) * 8.0;
  float span = 9.0 + imageUnit(columnKey ^ 0x27d4eb2du) * 12.0;
  float offset = imageUnit(columnKey ^ 0xd3a2646cu) * span;
  float phase = mod(float(globalCell.y) - uImageRainElapsed * speed + offset, span);
  if (phase < 0.0) phase += span;
  float head = exp(-phase * 0.55);
  float afterglow = phase < span * 0.42 ? pow(1.0 - phase / (span * 0.42), 2.0) : 0.0;
  return min(1.0, max(head, afterglow * 0.65));
}

float imageGlyphForLuminance(float luminance, uint key) {
  float value = clamp(luminance, 0.0, 1.0);
  int level = clamp(int(floor(value * 7.0)), 0, 6);
  int digitStart = int(uRainRanges.x + 0.5);
  int latinStart = int(uRainRanges.y + 0.5);
  int symbolStart = int(uRainRanges.z + 0.5);
  if (uGlyphMode == 2) return float(digitStart + (value >= 0.58 ? 0 : 1));
  if (uGlyphMode == 3) {
    const int digits[7] = int[7](1, 7, 4, 2, 5, 8, 0);
    return float(digitStart + digits[level]);
  }
  if (uGlyphMode == 4) {
    const int letters[7] = int[7](8, 11, 19, 0, 13, 12, 22);
    return float(latinStart + letters[level]);
  }
  if (uGlyphMode == 5) {
    const int symbols[7] = int[7](1, 6, 4, 5, 2, 3, 0);
    return float(symbolStart + symbols[level]);
  }
  if (uGlyphMode == 1) {
    return floor(imageUnit(key ^ uint(level) * 0x045d9f3bu) * float(digitStart));
  }
  if (value < 0.16) return float(symbolStart + 1);
  if (value < 0.32) return float(digitStart + 1);
  if (value < 0.48) return float(latinStart + 8);
  if (value < 0.64) return float(latinStart + 12);
  return floor(imageUnit(key ^ uint(level) * 0x045d9f3bu) * float(digitStart));
}

float randomRainGlyph(uint key) {
  int digitStart = int(uRainRanges.x + 0.5);
  int latinStart = int(uRainRanges.y + 0.5);
  int symbolStart = int(uRainRanges.z + 0.5);
  float pick = imageUnit(key ^ 0x68e31da4u);
  if (uGlyphMode == 2) return float(digitStart + int(pick * 2.0));
  if (uGlyphMode == 1) return floor(pick * float(digitStart));
  if (uGlyphMode == 3) return float(digitStart + int(pick * 10.0));
  if (uGlyphMode == 4) return float(latinStart + int(pick * 26.0));
  if (uGlyphMode == 5) return float(symbolStart + int(pick * 7.0));
  float group = imageUnit(key ^ 0xb5297a4du);
  int start = 0;
  int count = digitStart;
  if (group >= 0.96) { start = symbolStart; count = 7; }
  else if (group >= 0.91) { start = latinStart; count = 26; }
  else if (group >= 0.80) { start = digitStart; count = 10; }
  return float(start + int(pick * float(count)));
}

void main() {
  // Pixel -> cell. Row 0 is the top of the screen. uColOffset shifts this layer horizontally so
  // overlap layers fall between the base columns; the column index wraps so the shift tiles seamlessly.
  vec2 pixel = vec2(vUv.x * uViewport.x, (1.0 - vUv.y) * uViewport.y);
  float colF = (pixel.x - uGridOrigin.x) / uCell.x - uColOffset;
  float rowF = (pixel.y - uGridOrigin.y) / uCell.y;
  vec2 cellId = vec2(mod(floor(colF), uGrid.x), floor(rowF));
  vec2 cellUv = vec2(fract(colF), fract(rowF));
  vec2 stUv = (cellId + 0.5) / uGrid;

  vec4 st = texture(uState, stUv);
  float giNew = floor(st.r * 255.0 + 0.5);
  float bright = st.g;
  int b = int(floor(st.b * 255.0 + 0.5));
  bool isHead = (b & 128) != 0;
  bool whiteHead = (b & 64) != 0;
  float phase = float(b & 63) / 63.0;
  float giOld = floor(st.a * 255.0 + 0.5);

  // Renderer-only image reveal. It changes local shader values but never the canonical state texture.
  if (uImageEnabled != 0) {
    ivec2 globalCell = ivec2(cellId + uGlobalCellOffset);
    vec2 imageUv = (vec2(globalCell) + 0.5 - uImageRect.xy) / uImageRect.zw;
    if (all(greaterThanEqual(imageUv, vec2(0.0))) && all(lessThanEqual(imageUv, vec2(1.0)))) {
      float imageLuminance = sampleImageMask(imageUv);
      float signal = imageSignal(imageLuminance);
      if (signal > 0.001) signal *= imageEdgeFeather(imageUv);
      if (signal > 0.001) {
        uint identity = imageHash(
          uImageSeed ^ uint(globalCell.x) * 73856093u ^ uint(globalCell.y) * 19349663u);
        float packedBrightness = bright;
        float trailGate = clamp((bright - 0.028) / 0.42, 0.0, 1.0);
        float fallingGate = imageFallingGate(globalCell);
        float revealGate = max(trailGate, fallingGate * 0.48);
        float dissolve = 1.0;
        if (uImageScramble > 0.0) {
          float roll = imageUnit(identity ^ uImageAnimationBucket * 0x9e3779b9u ^ 0xb4b82e39u);
          dissolve = roll >= uImageScramble ? 1.0 : 0.0;
        }
        float influence = min(1.0, signal * revealGate * uImageIntensity * dissolve);
        if (influence > 0.001) {
          uint imageKey = identity ^ uint(floor(imageLuminance * 255.0)) * 0x85ebca6bu;
          float imageGlyph = imageGlyphForLuminance(imageLuminance, imageKey);
          float imageBright = max(0.0, (imageLuminance - 0.38) / 0.62);
          float imageDark = max(0.0, (0.58 - imageLuminance) / 0.58);
          bright *= 1.0 - 0.46 * imageDark * influence;
          bright = max(bright, imageBright * influence * (0.12 + 0.48 * fallingGate));
          bright = min(1.45, bright + imageBright * influence * max(packedBrightness, 0.08) * 0.58);

          float glyphRoll = imageUnit(identity ^ uImageAnimationBucket * 0x27d4eb2du ^ 0x68e31da4u);
          if (giNew < uRainRanges.w && glyphRoll < min(0.96, 0.18 + influence * 0.78)) {
            float replacement = imageGlyph;
            float scrambleRoll = imageUnit(identity ^ uImageAnimationBucket * 0x85ebca6bu ^ 0xd3a2646cu);
            if (uImageScramble > 0.0 && scrambleRoll < uImageScramble * 0.75) {
              replacement = randomRainGlyph(identity ^ uImageAnimationBucket ^ 0x3c6ef372u);
            }
            giOld = giNew;
            giNew = replacement;
            phase = 1.0;
          }
        }
      }
    }
  }

  // Continuous (non-fract) atlas-UV gradients shared by both glyph samples (computed before any
  // branch so textureGrad stays valid — it uses these explicit gradients, not implicit derivatives).
  vec2 duvdx = vec2(dFdx(colF), dFdx(rowF)) / uAtlasGrid;
  vec2 duvdy = vec2(dFdy(colF), dFdy(rowF)) / uAtlasGrid;
  float inkNew = sampleGlyph(giNew, cellUv, duvdx, duvdy);
  // Once the crossfade finishes (phase == 1) mix(old, new, 1) == new exactly, so skip the second
  // atlas fetch — most cells are settled, so they pay one glyph sample instead of two.
  float ink = phase < 1.0 ? mix(sampleGlyph(giOld, cellUv, duvdx, duvdy), inkNew, phase) : inkNew;

  // Head/body/tail color ramp (exponential brightness already baked in the sim).
  vec3 col = mix(uTail, uBody, smoothstep(0.0, 0.5, bright));
  col = mix(col, uBright, smoothstep(0.55, 0.95, bright));
  col = mix(col, uHead, (whiteHead ? 1.0 : 0.0) * smoothstep(0.8, 1.0, bright));
  float sparklePulse = max(isHead ? 0.45 : 0.0, 4.0 * phase * (1.0 - phase));
  float goldSparkle = uGoldSparkle * sparklePulse * smoothstep(0.45, 0.95, bright);
  col = mix(col, uHead, goldSparkle);

  float baseI = bright * ink;
  // Every head pops; white heads get the extra lead-brightness push (and bloom).
  float headExtra = isHead ? (0.6 + (whiteHead ? uLeadBrightness : 0.0)) : 0.0;
  float displayI = baseI * (1.0 + headExtra + goldSparkle);

  frag = vec4(col * displayI, baseI * (headExtra + goldSparkle * goldSparkleBloom));
}
