#version 300 es
precision highp float;

// Glyph pass: map each pixel to a grid cell, read the cell's packed state, sample
// the glyph atlas (old + new, crossfaded), and output the green ramp.
//   frag.rgb = on-screen color * display intensity (may exceed 1 in HDR mode)
//   frag.a   = bloom mask — non-zero only for heads, so only heads bloom.

in vec2 vUv;
out vec4 frag;

uniform sampler2D uState; // cols x rows, RGBA8 (NEAREST)
uniform sampler2D uAtlas; // glyph atlas (LINEAR + mips)
uniform vec2 uGrid;       // (cols, rows)
uniform vec2 uAtlasGrid;  // (atlasCols, atlasRows)
uniform vec3 uTail;
uniform vec3 uBody;
uniform vec3 uBright;
uniform vec3 uHead;
uniform float uLeadBrightness; // extra HDR for white-hot heads

// Gradients of the atlas UV taken from the *continuous* cell coordinate, so the
// fract() seam between cells doesn't blow up the implicit LOD (which would force
// the coarsest mip and draw a bright box outline around bloomed heads).
float sampleGlyph(float gi, vec2 cellUv, vec2 duvdx, vec2 duvdy) {
  float ax = mod(gi, uAtlasGrid.x);
  float ay = floor(gi / uAtlasGrid.x);
  vec2 uv = (vec2(ax, ay) + cellUv) / uAtlasGrid;
  return textureGrad(uAtlas, uv, duvdx, duvdy).a;
}

void main() {
  // Pixel -> cell. Row 0 is the top of the screen.
  float colF = vUv.x * uGrid.x;
  float rowF = (1.0 - vUv.y) * uGrid.y;
  vec2 cellId = vec2(floor(colF), floor(rowF));
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

  // Continuous (non-fract) atlas-UV gradients shared by both glyph samples.
  vec2 duvdx = vec2(dFdx(colF), dFdx(rowF)) / uAtlasGrid;
  vec2 duvdy = vec2(dFdy(colF), dFdy(rowF)) / uAtlasGrid;
  float ink = mix(sampleGlyph(giOld, cellUv, duvdx, duvdy), sampleGlyph(giNew, cellUv, duvdx, duvdy), phase);

  // Head/body/tail color ramp (exponential brightness already baked in the sim).
  vec3 col = mix(uTail, uBody, smoothstep(0.0, 0.5, bright));
  col = mix(col, uBright, smoothstep(0.55, 0.95, bright));
  col = mix(col, uHead, (whiteHead ? 1.0 : 0.0) * smoothstep(0.8, 1.0, bright));

  float baseI = bright * ink;
  // Every head pops; white heads get the extra lead-brightness push (and bloom).
  float headExtra = isHead ? (0.6 + (whiteHead ? uLeadBrightness : 0.0)) : 0.0;
  float displayI = baseI * (1.0 + headExtra);

  frag = vec4(col * displayI, baseI * headExtra);
}
