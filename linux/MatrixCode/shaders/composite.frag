in vec2 vUv;
out vec4 frag;

uniform sampler2D uScene;
uniform sampler2D uBloom;
uniform vec3 uBackground;
uniform float uGlow;
uniform float uScanline;
uniform float uVignette;
uniform vec2 uResolution;

vec3 aces(vec3 value) {
  const float a = 2.51;
  const float b = 0.03;
  const float c = 2.43;
  const float d = 0.59;
  const float e = 0.14;
  return clamp((value * (a * value + b)) /
    (value * (c * value + d) + e), 0.0, 1.0);
}

void main() {
  vec3 color = aces(texture(uScene, vUv).rgb + uGlow * texture(uBloom, vUv).rgb);
  color = max(color, uBackground);
  if (uScanline > 0.0) {
    float lines = 0.5 + 0.5 * sin(vUv.y * uResolution.y * 1.5);
    color *= 1.0 - uScanline * (1.0 - lines);
  }
  if (uVignette > 0.0) {
    float distanceFromCenter = length((vUv - 0.5) / vec2(0.42, 0.42));
    float value = 1.0 - smoothstep(0.15, 0.95, distanceFromCenter);
    color *= mix(1.0, pow(value, 2.8), uVignette);
  }
  frag = vec4(color, 1.0);
}
