#version 300 es
precision highp float;

// Separable 9-tap Gaussian. Run twice per level (horizontal then vertical).

in vec2 vUv;
out vec4 frag;

uniform sampler2D uTex;
uniform vec2 uDir; // (texelW, 0) or (0, texelH), pre-scaled by spread

const float w0 = 0.227027;
const float w1 = 0.1945946;
const float w2 = 0.1216216;
const float w3 = 0.054054;
const float w4 = 0.016216;

void main() {
  vec3 c = texture(uTex, vUv).rgb * w0;
  c += texture(uTex, vUv + uDir * 1.0).rgb * w1;
  c += texture(uTex, vUv - uDir * 1.0).rgb * w1;
  c += texture(uTex, vUv + uDir * 2.0).rgb * w2;
  c += texture(uTex, vUv - uDir * 2.0).rgb * w2;
  c += texture(uTex, vUv + uDir * 3.0).rgb * w3;
  c += texture(uTex, vUv - uDir * 3.0).rgb * w3;
  c += texture(uTex, vUv + uDir * 4.0).rgb * w4;
  c += texture(uTex, vUv - uDir * 4.0).rgb * w4;
  frag = vec4(c, 1.0);
}
