#version 300 es
precision highp float;

// Plain texture copy. Used for down/upsampling between bloom mip levels
// (LINEAR sampling does the resampling); combined with additive blending it
// sums the blurred levels back together.

in vec2 vUv;
out vec4 frag;

uniform sampler2D uTex;

void main() {
  frag = texture(uTex, vUv);
}
