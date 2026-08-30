import { createRng } from "../util/rng.ts";
import { effectivePresetName, getPreset } from "../config/colorPresets.ts";
import type { ImagesDoc, PresetName } from "../types.ts";
import type { ActiveImageFrame } from "../sim/imageScheduler.ts";
import { imageUnit } from "../sim/imageScheduler.ts";
import {
  imageCellIdentity,
  imageEdgeFeather,
  imageFallingGate,
  imageRevealGeometry,
  imageSignal,
  sampleImageMask,
} from "../sim/imageReveal.ts";

// Classic Canvas2D digital rain used only when WebGL2 is unavailable. Lower
// fidelity (no real bloom) but still authentic: mirrored half-width katakana,
// white leading glyph, translucent-black trail fade, per-column speeds.

export interface Canvas2dRainHandle {
  start: () => void;
  stop: () => void;
  /** Paint a deterministic, warmed rain frame without leaving an animation running. */
  renderStatic: (nowMs?: number) => void;
  /** Recolor the last frame without advancing rain or image timelines. */
  refreshTheme: () => void;
}

export interface CanvasImageRevealSource {
  frame: ActiveImageFrame | null;
  doc: ImagesDoc;
  seed: number;
}

export interface CanvasFrameDecision {
  render: boolean;
  elapsedMs: number;
}

export function shouldSparkleGoldHead(preset: PresetName, random: () => number): boolean {
  return preset === "gold" && random() < 0.05;
}

function rgb(c: readonly [number, number, number], a = 1): string {
  return `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${a})`;
}

export function startCanvas2dRain(
  canvas: HTMLCanvasElement,
  preset: PresetName = "classic",
  glyphScale = 1,
  customColor?: string,
  imageSource?: (nowMs: number) => CanvasImageRevealSource,
  frameGate?: (nowMs: number) => CanvasFrameDecision,
): Canvas2dRainHandle {
  const ctx0 = canvas.getContext("2d");
  if (!ctx0) return { start: () => {}, stop: () => {}, renderStatic: () => {}, refreshTheme: () => {} };
  const ctx = ctx0; // non-null, captured by the animation closures

  let colors = getPreset(effectivePresetName(preset), customColor);
  const chars: string[] = [];
  for (let cp = 0xff66; cp <= 0xff9d; cp++) chars.push(String.fromCodePoint(cp));
  for (const d of "0123456789") chars.push(d);

  const rng = createRng(7);
  const sparkleRng = createRng(17);
  let pixelRatio = 1;
  let fontSize = 18 * glyphScale;
  const staticWarmupFrames = 150;
  let cols = 0;
  let drops: number[] = [];
  let speeds: number[] = [];
  let running = false;
  let raf = 0;
  let lastGlyphs: Array<{ x: number; y: number; text: string; sparkling: boolean }> = [];
  let lastImageSource: CanvasImageRevealSource | undefined;

  function layout(): void {
    const cssWidth = canvas.clientWidth || canvas.width;
    const cssHeight = canvas.clientHeight || canvas.height;
    const widthRatio = cssWidth > 0 ? canvas.width / cssWidth : 1;
    const heightRatio = cssHeight > 0 ? canvas.height / cssHeight : widthRatio;
    pixelRatio = Math.max(Number.EPSILON, Math.min(widthRatio, heightRatio));
    fontSize = 18 * glyphScale * pixelRatio;
    cols = Math.max(1, Math.floor(canvas.width / fontSize));
    drops = new Array(cols);
    speeds = new Array(cols);
    for (let i = 0; i < cols; i++) {
      drops[i] = Math.floor(rng() * -50);
      speeds[i] = 0.4 + rng() * 0.9;
    }
  }
  layout();
  let lastW = canvas.width;
  let lastH = canvas.height;

  let bg = rgb(colors.background, 1);
  let standardFadeBackground = rgb(colors.background, 0.08);
  let headColor = rgb(colors.head, 1);
  let brightColor = rgb(colors.bright, 1);

  function refreshColors(): boolean {
    const name = effectivePresetName(preset);
    if (colors.name === name) return false;
    colors = getPreset(name, customColor);
    bg = rgb(colors.background, 1);
    standardFadeBackground = rgb(colors.background, 0.08);
    headColor = rgb(colors.head, 1);
    brightColor = rgb(colors.bright, 1);
    // Trails are baked into the canvas, so discard pixels from the previous palette.
    // The rain's positions, speeds, and random streams continue unchanged.
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    return true;
  }

  function drawImageReveal(source: CanvasImageRevealSource | undefined, rows: number): void {
    const active = source?.frame;
    if (!source || !active) return;
    const geometry = imageRevealGeometry(active, source.doc, cols, rows);
    const firstCol = Math.max(0, Math.floor(geometry.originCol));
    const lastCol = Math.min(cols - 1, Math.ceil(geometry.originCol + geometry.cols));
    const firstRow = Math.max(0, Math.floor(geometry.originRow));
    const lastRow = Math.min(Math.ceil(rows) - 1, Math.ceil(geometry.originRow + geometry.rows));
    ctx.save();
    ctx.font = `${fontSize}px monospace`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillStyle = brightColor;
    ctx.shadowColor = brightColor;
    ctx.shadowBlur = 9 * pixelRatio;
    for (let row = firstRow; row <= lastRow; row++) {
      for (let col = firstCol; col <= lastCol; col++) {
        const u = (col + 0.5 - geometry.originCol) / geometry.cols;
        const v = (row + 0.5 - geometry.originRow) / geometry.rows;
        if (u < 0 || u > 1 || v < 0 || v > 1) continue;
        const luminance = sampleImageMask(active.mask, active.image.width, active.image.height, u, v);
        const signal = imageSignal(luminance) * imageEdgeFeather(u, v, geometry.featherU, geometry.featherV);
        if (signal <= 0.001) continue;
        const identity = imageCellIdentity(source.seed, col, row);
        if (
          active.scramble > 0 &&
          imageUnit((identity ^ Math.imul(active.animationBucket, 0x9e3779b9) ^ 0xb4b82e39) >>> 0) < active.scramble
        ) continue;
        const gate = imageFallingGate(col, row, active.rainElapsed, source.seed) * 0.48;
        const influence = Math.min(1, signal * gate * active.intensity);
        if (influence <= 0.001) continue;
        const levels = "·:+*MW";
        const glyph = levels[Math.min(levels.length - 1, Math.floor(luminance * levels.length))]!;
        ctx.globalAlpha = Math.max(0.08, influence);
        ctx.save();
        ctx.translate(col * fontSize + fontSize / 2, row * fontSize + fontSize / 2);
        ctx.scale(-1, 1);
        ctx.fillText(glyph, 0, 0);
        ctx.restore();
      }
    }
    ctx.restore();
  }

  function drawLastFrame(): void {
    ctx.font = `${fontSize}px monospace`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    for (const glyph of lastGlyphs) {
      ctx.save();
      ctx.translate(glyph.x, glyph.y);
      ctx.scale(-1, 1); // mirror, as in the film
      ctx.fillStyle = headColor;
      ctx.shadowColor = brightColor;
      const sparkling = colors.name === "gold" && glyph.sparkling;
      if (sparkling) {
        ctx.globalAlpha = 0.4;
        ctx.shadowBlur = 18 * pixelRatio;
        ctx.fillText(glyph.text, 0, 0);
        ctx.globalAlpha = 1;
      }
      ctx.shadowBlur = (sparkling ? 12 : 8) * pixelRatio;
      ctx.fillText(glyph.text, 0, 0);
      ctx.restore();
    }
    drawImageReveal(lastImageSource, canvas.height / fontSize);
  }

  function paint(nowMs: number, frameScale: number, includeImageReveal = true): void {
    refreshColors();
    if (canvas.width !== lastW || canvas.height !== lastH) {
      lastW = canvas.width;
      lastH = canvas.height;
      layout();
      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, canvas.width, canvas.height);
    }

    // Translucent fade leaves decaying trails.
    const fadeAlpha = frameGate ? 1 - Math.pow(1 - 0.08, frameScale) : 0.08;
    ctx.fillStyle = frameGate ? rgb(colors.background, fadeAlpha) : standardFadeBackground;
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    const rows = canvas.height / fontSize;
    lastGlyphs = [];
    for (let i = 0; i < cols; i++) {
      const y = drops[i]!;
      if (y >= 0) {
        lastGlyphs.push({
          x: i * fontSize + fontSize / 2,
          y: y * fontSize + fontSize / 2,
          text: chars[Math.floor(rng() * chars.length)]!,
          sparkling: shouldSparkleGoldHead(colors.name, sparkleRng),
        });
      }
      drops[i]! += speeds[i]! * frameScale;
      if (y * fontSize > canvas.height && rng() > 0.975) drops[i] = Math.floor(rng() * -20);
      if (y > rows + 40) drops[i] = Math.floor(rng() * -20);
    }
    lastImageSource = includeImageReveal ? imageSource?.(nowMs) : undefined;
    drawLastFrame();
  }

  function frame(nowMs: number): void {
    if (!running) return;
    raf = requestAnimationFrame(frame);
    const decision = frameGate?.(nowMs);
    if (decision && !decision.render) return;
    const frameScale = decision && decision.elapsedMs > 0
      ? Math.min(8, decision.elapsedMs / (1000 / 60))
      : 1;
    paint(nowMs, frameScale);
  }

  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  const start = (): void => {
    if (running) return;
    running = true;
    raf = requestAnimationFrame(frame);
  };
  start();

  return {
    start,
    refreshTheme: () => {
      if (refreshColors()) drawLastFrame();
    },
    stop: () => {
      running = false;
      cancelAnimationFrame(raf);
    },
    renderStatic: (nowMs = performance.now()) => {
      refreshColors();
      const wasRunning = running;
      if (wasRunning) {
        running = false;
        cancelAnimationFrame(raf);
      }
      // The animated fallback normally enters from above the viewport. A reduced-motion
      // load has no RAFs in which to reach the screen, so advance the same deterministic
      // state offscreen and retain the resulting representative frame.
      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      for (let index = 0; index < staticWarmupFrames; index++) {
        paint(nowMs, 1, index === staticWarmupFrames - 1);
      }
      if (wasRunning) {
        running = true;
        raf = requestAnimationFrame(frame);
      }
    },
  };
}
