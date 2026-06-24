#version 300 es
precision highp float;

// Bright-pass + first downsample: keep only the head bloom energy (scene.a), tinted
// by the head's own color, with a Karis average to tame firefly sparkle.

in vec2 vUv;
out vec4 frag;

uniform sampler2D uScene;

void main() {
  vec4 s = texture(uScene, vUv);
  float mask = s.a; // non-zero only for heads
  vec3 c = s.rgb * smoothstep(0.0, 0.15, mask);
  float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
  c *= 1.0 / (1.0 + luma); // Karis weight
  frag = vec4(c, 1.0);
}
