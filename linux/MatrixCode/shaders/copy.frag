in vec2 vUv;
out vec4 frag;

uniform sampler2D uTex;

void main() {
  frag = texture(uTex, vUv);
}
