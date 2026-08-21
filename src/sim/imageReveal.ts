import type { GlyphMode, ImagesDoc } from "../types.ts";
import type { GlyphSet } from "./glyphSet.ts";
import type { ActiveImageFrame } from "./imageScheduler.ts";
import { imageHash, imageUnit } from "./imageScheduler.ts";

export interface ImageRevealGeometry {
  originCol: number;
  originRow: number;
  cols: number;
  rows: number;
  featherU: number;
  featherV: number;
}

export interface ImageRenderState extends ImageRevealGeometry {
  mask: Uint8Array;
  maskWidth: number;
  maskHeight: number;
  intensity: number;
  scramble: number;
  placementX: number;
  placementY: number;
  rainElapsed: number;
  animationBucket: number;
  seed: number;
  globalColStart: number;
  globalRowStart: number;
  glyphMode: GlyphMode;
  digitStart: number;
  latinStart: number;
  symbolStart: number;
  messageStart: number;
}

export function imageRevealGeometry(
  frame: ActiveImageFrame,
  doc: ImagesDoc,
  virtualCols: number,
  virtualRows: number,
): ImageRevealGeometry {
  const targetCols = Math.max(1, virtualCols * doc.imageScale);
  const aspect = frame.image.width / Math.max(1, frame.image.height);
  let cols = Math.min(virtualCols, targetCols);
  let rows = cols / Math.max(0.001, aspect);
  if (rows > virtualRows) {
    rows = virtualRows;
    cols = Math.min(virtualCols, rows * aspect);
  }
  const remainingCols = Math.max(0, virtualCols - cols);
  const remainingRows = Math.max(0, virtualRows - rows);
  const jitter = doc.imageScale >= 0.999 ? 0 : doc.imagePlacementJitter;
  const x = 0.5 + (frame.placementX - 0.5) * jitter;
  const y = 0.5 + (frame.placementY - 0.5) * jitter;
  const featherCols = Math.min(4, Math.max(1, cols * 0.04));
  const featherRows = Math.min(4, Math.max(1, rows * 0.04));
  return {
    originCol: remainingCols * Math.min(1, Math.max(0, x)),
    originRow: remainingRows * Math.min(1, Math.max(0, y)),
    cols,
    rows,
    featherU: featherCols / Math.max(1, cols),
    featherV: featherRows / Math.max(1, rows),
  };
}

export function buildImageRenderState(args: {
  frame: ActiveImageFrame | null;
  doc: ImagesDoc;
  virtualCols: number;
  virtualRows: number;
  globalColStart?: number;
  globalRowStart?: number;
  seed: number;
  glyphSet: GlyphSet;
}): ImageRenderState | undefined {
  const { frame } = args;
  if (!frame) return undefined;
  return {
    ...imageRevealGeometry(frame, args.doc, args.virtualCols, args.virtualRows),
    mask: frame.mask,
    maskWidth: frame.image.width,
    maskHeight: frame.image.height,
    intensity: frame.intensity,
    scramble: frame.scramble,
    placementX: frame.placementX,
    placementY: frame.placementY,
    rainElapsed: frame.rainElapsed,
    animationBucket: frame.animationBucket,
    seed: args.seed >>> 0,
    globalColStart: args.globalColStart ?? 0,
    globalRowStart: args.globalRowStart ?? 0,
    glyphMode: args.glyphSet.glyphMode,
    digitStart: args.glyphSet.ranges.digits.start,
    latinStart: args.glyphSet.ranges.latin.start,
    symbolStart: args.glyphSet.ranges.symbols.start,
    messageStart: args.glyphSet.ranges.message.start,
  };
}

export function smoothstep(edge0: number, edge1: number, value: number): number {
  if (edge0 === edge1) return value < edge0 ? 0 : 1;
  const t = Math.min(1, Math.max(0, (value - edge0) / (edge1 - edge0)));
  return t * t * (3 - 2 * t);
}

export function sampleImageMask(mask: Uint8Array, width: number, height: number, u: number, v: number): number {
  if (mask.length !== width * height || width < 1 || height < 1 || u < 0 || u > 1 || v < 0 || v > 1) {
    return 0;
  }
  const x = Math.min(width - 1, Math.max(0, u * (width - 1)));
  const y = Math.min(height - 1, Math.max(0, v * (height - 1)));
  const x0 = Math.floor(x);
  const y0 = Math.floor(y);
  const x1 = Math.min(width - 1, x0 + 1);
  const y1 = Math.min(height - 1, y0 + 1);
  const tx = x - x0;
  const ty = y - y0;
  const a = mask[y0 * width + x0]! / 255;
  const b = mask[y0 * width + x1]! / 255;
  const c = mask[y1 * width + x0]! / 255;
  const d = mask[y1 * width + x1]! / 255;
  const top = a + (b - a) * tx;
  return top + (c + (d - c) * tx - top) * ty;
}

export function imageSignal(luminance: number): number {
  const value = Math.min(1, Math.max(0, luminance));
  const nonEmpty = smoothstep(0.035, 0.12, value);
  const contrast = Math.abs(value - 0.5) * 2 * nonEmpty;
  const bright = value * 0.72;
  return Math.max(contrast, bright) * nonEmpty;
}

export function imageEdgeFeather(u: number, v: number, featherU: number, featherV: number): number {
  const horizontal = Math.min(smoothstep(0, featherU, u), smoothstep(0, featherU, 1 - u));
  const vertical = Math.min(smoothstep(0, featherV, v), smoothstep(0, featherV, 1 - v));
  return horizontal * vertical;
}

export function imageFallingGate(globalCol: number, globalRow: number, rainElapsed: number, seed: number): number {
  const columnKey = (seed ^ Math.imul(globalCol | 0, 0x9e3779b9) ^ 0x748f4a15) >>> 0;
  const speed = 4.5 + imageUnit((columnKey ^ 0x85ebca6b) >>> 0) * 8;
  const span = 9 + imageUnit((columnKey ^ 0x27d4eb2d) >>> 0) * 12;
  const offset = imageUnit((columnKey ^ 0xd3a2646c) >>> 0) * span;
  let phase = (globalRow - rainElapsed * speed + offset) % span;
  if (phase < 0) phase += span;
  const head = Math.exp(-phase * 0.55);
  const afterglow = phase < span * 0.42 ? Math.pow(1 - phase / (span * 0.42), 2) : 0;
  return Math.min(1, Math.max(head, afterglow * 0.65));
}

export function imageCellIdentity(seed: number, globalCol: number, globalRow: number): number {
  return imageHash(
    (seed ^ Math.imul(globalCol | 0, 73856093) ^ Math.imul(globalRow | 0, 19349663)) >>> 0,
  );
}
