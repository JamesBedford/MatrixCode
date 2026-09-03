in vec2 vUv;
out vec4 frag;

uniform sampler2D uTex;
uniform vec2 uDir;

const float w0 = 0.2270270;
const float w12 = 0.3162162;
const float w34 = 0.0702703;
const float o12 = 1.3846154;
const float o34 = 3.2307692;

void main() {
  vec3 color = texture(uTex, vUv).rgb * w0;
  color += texture(uTex, vUv + uDir * o12).rgb * w12;
  color += texture(uTex, vUv - uDir * o12).rgb * w12;
  color += texture(uTex, vUv + uDir * o34).rgb * w34;
  color += texture(uTex, vUv - uDir * o34).rgb * w34;
  frag = vec4(color, 1.0);
}
