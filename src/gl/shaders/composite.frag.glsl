#version 300 es
precision highp float;

// Final composite: add bloom, ACES tone-map, apply the background as a dark FLOOR
// (max, not add — keeps the screen overwhelmingly black), then optional CRT touches.

in vec2 vUv;
out vec4 frag;

uniform sampler2D uScene;
uniform sampler2D uBloom;
uniform vec3 uBackground;
uniform float uGlow;
uniform float uScanline; // 0 = off
uniform float uVignette; // 0 = off
uniform vec2 uResolution;

vec3 aces(vec3 x) {
  // Narkowicz ACES filmic approximation.
  const float a = 2.51;
  const float b = 0.03;
  const float c = 2.43;
  const float d = 0.59;
  const float e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
  vec3 scene = texture(uScene, vUv).rgb;
  vec3 bloom = texture(uBloom, vUv).rgb;
  vec3 col = aces(scene + uGlow * bloom);

  // Background as a floor so dark areas read as Vampire Black, not lifted grey.
  col = max(col, uBackground);

  if (uScanline > 0.0) {
    float lines = 0.5 + 0.5 * sin(vUv.y * uResolution.y * 1.5);
    col *= 1.0 - uScanline * (1.0 - lines);
  }

  if (uVignette > 0.0) {
    // Start the falloff earlier so the vignette is visible beyond just the corners.
    float d = length((vUv - 0.5) / vec2(0.42, 0.42));
    // GLSL leaves smoothstep undefined when edge0 >= edge1. Express the same
    // reversed ramp with ordered edges so WebGL and Metal share defined math.
    float v = 1.0 - smoothstep(0.15, 0.95, d);
    // Blend toward a steeper falloff so 100% reads as a clearly stronger vignette.
    col *= mix(1.0, pow(v, 2.8), uVignette);
  }

  frag = vec4(col, 1.0);
}
