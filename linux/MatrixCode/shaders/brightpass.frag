in vec2 vUv;
out vec4 frag;

uniform sampler2D uScene;

void main() {
  vec4 scene = texture(uScene, vUv);
  vec3 color = scene.rgb * smoothstep(0.0, 0.15, scene.a);
  float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
  color *= 1.0 / (1.0 + luma);
  frag = vec4(color, 1.0);
}
