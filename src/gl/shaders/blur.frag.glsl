#version 300 es
precision highp float;

// Separable Gaussian, run twice per level (horizontal then vertical). The original
// 9-tap kernel is collapsed to 5 texture fetches using linear-sampling: each pair of
// adjacent weighted taps is replaced by ONE bilinear fetch at a fractional offset whose
// weight is the pair's sum and whose position is their weighted average, so hardware
// LINEAR filtering does two taps' work in one fetch. Same Gaussian, ~44% fewer samples.
//   w12 = w1+w2,  o12 = (1*w1 + 2*w2)/w12     (in units of uDir)
//   w34 = w3+w4,  o34 = (3*w3 + 4*w4)/w34
// from the original discrete weights w0..w4 = 0.227027,0.1945946,0.1216216,0.054054,0.016216.

in vec2 vUv;
out vec4 frag;

uniform sampler2D uTex;
uniform vec2 uDir; // (texelW, 0) or (0, texelH), pre-scaled by spread

const float w0 = 0.2270270;
const float w12 = 0.3162162;
const float w34 = 0.0702703;
const float o12 = 1.3846154;
const float o34 = 3.2307692;

void main() {
  vec3 c = texture(uTex, vUv).rgb * w0;
  c += texture(uTex, vUv + uDir * o12).rgb * w12;
  c += texture(uTex, vUv - uDir * o12).rgb * w12;
  c += texture(uTex, vUv + uDir * o34).rgb * w34;
  c += texture(uTex, vUv - uDir * o34).rgb * w34;
  frag = vec4(c, 1.0);
}
