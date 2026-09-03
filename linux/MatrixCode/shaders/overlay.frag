in vec2 vUv;
out vec4 frag;

uniform sampler2D uOverlay;
uniform vec2 uOutputSize;
uniform vec2 uOverlayOrigin;
uniform vec2 uOverlaySize;
uniform float uOverlayOpacity;

void main() {
  vec2 outputPixel = vec2(vUv.x * uOutputSize.x, (1.0 - vUv.y) * uOutputSize.y);
  vec2 relative = outputPixel - uOverlayOrigin;
  if (relative.x < 0.0 || relative.y < 0.0 ||
      relative.x >= uOverlaySize.x || relative.y >= uOverlaySize.y) {
    frag = vec4(0.0);
    return;
  }
  frag = texture(uOverlay, relative / uOverlaySize) * uOverlayOpacity;
}
