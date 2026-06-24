import * as twgl from "twgl.js";
import type { Grid, QualityTier, RenderParams } from "../types.ts";
import type { GlyphAtlas } from "./glyphAtlas.ts";
import type { StateTexture } from "./stateTexture.ts";
import { createFullscreenTri, drawFullscreen } from "./fullscreenTri.ts";

import fullscreenVert from "./shaders/fullscreen.vert.glsl?raw";
import glyphFrag from "./shaders/glyph.frag.glsl?raw";
import brightFrag from "./shaders/brightpass.frag.glsl?raw";
import blurFrag from "./shaders/blur.frag.glsl?raw";
import copyFrag from "./shaders/copy.frag.glsl?raw";
import compositeFrag from "./shaders/composite.frag.glsl?raw";

const BLOOM_LEVELS: Record<QualityTier, number> = { low: 1, med: 2, high: 3 };
const BLUR_SPREAD = 1.8;

interface BloomLevel {
  main: twgl.FramebufferInfo;
  tmp: twgl.FramebufferInfo;
  w: number;
  h: number;
}

export class Renderer {
  private gl: WebGL2RenderingContext;
  private atlas: GlyphAtlas;
  private state: StateTexture;

  private tri: twgl.BufferInfo;
  private glyphProg: twgl.ProgramInfo;
  private brightProg: twgl.ProgramInfo;
  private blurProg: twgl.ProgramInfo;
  private copyProg: twgl.ProgramInfo;
  private compositeProg: twgl.ProgramInfo;

  /** HDR-capable color format for the scene/bloom targets, with graceful fallback. */
  readonly hdr: boolean;
  private internalFormat: number;
  private texType: number;

  private deviceW = 1;
  private deviceH = 1;
  private quality: QualityTier = "high";
  private scene!: twgl.FramebufferInfo;
  private levels: BloomLevel[] = [];

  constructor(gl: WebGL2RenderingContext, atlas: GlyphAtlas, state: StateTexture) {
    this.gl = gl;
    this.atlas = atlas;
    this.state = state;

    // Detect renderable float targets. Sampling float textures is core in WebGL2;
    // rendering TO them needs an extension. Linear filtering of half-float is needed
    // for the blur chain.
    const canFloat = !!gl.getExtension("EXT_color_buffer_float");
    const canHalf = !!gl.getExtension("EXT_color_buffer_half_float");
    gl.getExtension("OES_texture_float_linear");
    this.hdr = canFloat || canHalf;
    this.internalFormat = this.hdr ? gl.RGBA16F : gl.RGBA8;
    this.texType = this.hdr ? gl.HALF_FLOAT : gl.UNSIGNED_BYTE;

    this.tri = createFullscreenTri(gl);
    this.glyphProg = twgl.createProgramInfo(gl, [fullscreenVert, glyphFrag]);
    this.brightProg = twgl.createProgramInfo(gl, [fullscreenVert, brightFrag]);
    this.blurProg = twgl.createProgramInfo(gl, [fullscreenVert, blurFrag]);
    this.copyProg = twgl.createProgramInfo(gl, [fullscreenVert, copyFrag]);
    this.compositeProg = twgl.createProgramInfo(gl, [fullscreenVert, compositeFrag]);
  }

  setAtlas(atlas: GlyphAtlas): void {
    this.atlas = atlas;
  }

  private makeTarget(w: number, h: number): twgl.FramebufferInfo {
    return twgl.createFramebufferInfo(
      this.gl,
      [
        {
          internalFormat: this.internalFormat,
          type: this.texType,
          format: this.gl.RGBA,
          minMag: this.gl.LINEAR,
          wrap: this.gl.CLAMP_TO_EDGE,
        },
      ],
      w,
      h,
    );
  }

  /** (Re)allocate the scene + bloom targets for a device-pixel size and quality. */
  resize(deviceW: number, deviceH: number, quality: QualityTier): void {
    const gl = this.gl;
    deviceW = Math.max(1, Math.floor(deviceW));
    deviceH = Math.max(1, Math.floor(deviceH));
    if (deviceW === this.deviceW && deviceH === this.deviceH && quality === this.quality && this.levels.length) {
      return;
    }
    this.disposeTargets();
    this.deviceW = deviceW;
    this.deviceH = deviceH;
    this.quality = quality;

    this.scene = this.makeTarget(deviceW, deviceH);

    const count = BLOOM_LEVELS[quality];
    for (let k = 0; k < count; k++) {
      const w = Math.max(1, deviceW >> (k + 1));
      const h = Math.max(1, deviceH >> (k + 1));
      this.levels.push({ main: this.makeTarget(w, h), tmp: this.makeTarget(w, h), w, h });
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  }

  renderFrame(params: RenderParams, grid: Grid): void {
    const gl = this.gl;
    if (params.quality !== this.quality) {
      this.resize(this.deviceW, this.deviceH, params.quality);
    }
    const tex = (fb: twgl.FramebufferInfo): WebGLTexture => fb.attachments[0] as WebGLTexture;
    const preset = params.preset;

    gl.disable(gl.BLEND);

    // 1. Glyph pass -> HDR scene.
    twgl.bindFramebufferInfo(gl, this.scene);
    drawFullscreen(gl, this.glyphProg, this.tri, {
      uState: this.state.texture,
      uAtlas: this.atlas.texture,
      uGrid: [grid.cols, grid.rows],
      uAtlasGrid: [this.atlas.atlasCols, this.atlas.atlasRows],
      uTail: preset.tail,
      uBody: preset.body,
      uBright: preset.bright,
      uHead: preset.head,
      uLeadBrightness: params.leadBrightness,
    });

    // 2. Bright-pass -> level 0 (half res).
    const levels = this.levels;
    twgl.bindFramebufferInfo(gl, levels[0]!.main);
    drawFullscreen(gl, this.brightProg, this.tri, { uScene: tex(this.scene) });

    // 3. Blur each level; downsample into the next.
    for (let k = 0; k < levels.length; k++) {
      const lv = levels[k]!;
      twgl.bindFramebufferInfo(gl, lv.tmp);
      drawFullscreen(gl, this.blurProg, this.tri, { uTex: tex(lv.main), uDir: [BLUR_SPREAD / lv.w, 0] });
      twgl.bindFramebufferInfo(gl, lv.main);
      drawFullscreen(gl, this.blurProg, this.tri, { uTex: tex(lv.tmp), uDir: [0, BLUR_SPREAD / lv.h] });
      if (k + 1 < levels.length) {
        const nx = levels[k + 1]!;
        twgl.bindFramebufferInfo(gl, nx.main);
        drawFullscreen(gl, this.copyProg, this.tri, { uTex: tex(lv.main) });
      }
    }

    // 4. Upsample-combine: additively fold higher levels down into level 0.
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE);
    for (let k = levels.length - 1; k >= 1; k--) {
      twgl.bindFramebufferInfo(gl, levels[k - 1]!.main);
      drawFullscreen(gl, this.copyProg, this.tri, { uTex: tex(levels[k]!.main) });
    }
    gl.disable(gl.BLEND);

    // 5. Composite -> default framebuffer.
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, this.deviceW, this.deviceH);
    drawFullscreen(gl, this.compositeProg, this.tri, {
      uScene: tex(this.scene),
      uBloom: tex(levels[0]!.main),
      uBackground: preset.background,
      uGlow: params.glow,
      uScanline: params.scanlines ? 0.12 : 0,
      uVignette: params.vignette ? 0.42 : 0,
      uResolution: [this.deviceW, this.deviceH],
    });
  }

  private disposeTargets(): void {
    const gl = this.gl;
    const free = (fb?: twgl.FramebufferInfo): void => {
      if (!fb) return;
      for (const a of fb.attachments) if (a instanceof WebGLTexture) gl.deleteTexture(a);
      if (fb.framebuffer) gl.deleteFramebuffer(fb.framebuffer);
    };
    free(this.scene);
    for (const lv of this.levels) {
      free(lv.main);
      free(lv.tmp);
    }
    this.levels = [];
  }

  dispose(): void {
    this.disposeTargets();
  }
}
