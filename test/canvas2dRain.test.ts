import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { DEFAULT_IMAGES, encodeBase64Mask } from "../src/config/imagesStore.ts";
import { shouldSparkleGoldHead, startCanvas2dRain } from "../src/fallback/canvas2dRain.ts";
import type { CanvasImageRevealSource } from "../src/fallback/canvas2dRain.ts";
import { WallpaperEngineFpsLimiter } from "../src/platform/wallpaperEngine.ts";
import { nextFullMoonMs } from "../src/sim/holidays.ts";
import * as imageReveal from "../src/sim/imageReveal.ts";

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date(2026, 0, 1));
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

function canvasHarness(): {
  canvas: HTMLCanvasElement;
  context: CanvasRenderingContext2D;
  fillRect: ReturnType<typeof vi.fn>;
  fillText: ReturnType<typeof vi.fn>;
  requestFrame: ReturnType<typeof vi.fn>;
  cancelFrame: ReturnType<typeof vi.fn>;
  pendingFrames: () => number;
  runNextFrame: (nowMs: number) => FrameRequestCallback;
} {
  const fillRect = vi.fn();
  const fillText = vi.fn();
  const context = {
    fillStyle: "",
    font: "",
    textAlign: "start",
    textBaseline: "alphabetic",
    shadowColor: "",
    shadowBlur: 0,
    globalAlpha: 1,
    fillRect,
    fillText,
    restore: vi.fn(),
    save: vi.fn(),
    scale: vi.fn(),
    translate: vi.fn(),
  } as unknown as CanvasRenderingContext2D;
  const canvas = {
    width: 180,
    height: 180,
    clientWidth: 180,
    clientHeight: 180,
    getContext: vi.fn((kind: string) => kind === "2d" ? context : null),
  } as unknown as HTMLCanvasElement;

  let nextFrameId = 0;
  const frames = new Map<number, FrameRequestCallback>();
  const requestFrame = vi.fn((callback: FrameRequestCallback): number => {
    const id = ++nextFrameId;
    frames.set(id, callback);
    return id;
  });
  const cancelFrame = vi.fn((id: number): void => {
    frames.delete(id);
  });
  vi.stubGlobal("requestAnimationFrame", requestFrame);
  vi.stubGlobal("cancelAnimationFrame", cancelFrame);

  return {
    canvas,
    context,
    fillRect,
    fillText,
    requestFrame,
    cancelFrame,
    pendingFrames: () => frames.size,
    runNextFrame: (nowMs: number): FrameRequestCallback => {
      const entry = frames.entries().next().value as [number, FrameRequestCallback] | undefined;
      if (!entry) throw new Error("Expected a pending animation frame");
      frames.delete(entry[0]);
      entry[1](nowMs);
      return entry[1];
    },
  };
}

describe("Canvas2D gold sparkle", () => {
  it("only samples and accepts the sparkle roll for gold", () => {
    const sparkling = vi.fn(() => 0.049);
    expect(shouldSparkleGoldHead("gold", sparkling)).toBe(true);
    expect(sparkling).toHaveBeenCalledOnce();

    const nonGold = vi.fn(() => 0);
    expect(shouldSparkleGoldHead("amber", nonGold)).toBe(false);
    expect(nonGold).not.toHaveBeenCalled();
  });

  it("keeps rolls at or above the five-percent threshold unlit", () => {
    expect(shouldSparkleGoldHead("gold", () => 0.05)).toBe(false);
  });
});

describe("Canvas2D host lifecycle", () => {
  it("recolors a paused full-moon frame White without advancing glyphs or resuming animation", () => {
    const harness = canvasHarness();
    const rain = startCanvas2dRain(harness.canvas, "gold");
    rain.renderStatic(0);
    rain.stop();
    harness.fillText.mockClear();
    vi.setSystemTime(nextFullMoonMs(Date.UTC(2026, 7, 20)));
    rain.refreshTheme();
    expect(harness.context.shadowColor).toBe("rgba(237,237,237,1)");
    expect(harness.context.shadowBlur).toBe(8);
    const whiteGlyphs = harness.fillText.mock.calls.slice();
    harness.fillText.mockClear();
    vi.setSystemTime(new Date(2026, 1, 14));
    rain.refreshTheme();
    expect(harness.fillText.mock.calls).toEqual(whiteGlyphs);
    expect(harness.context.shadowColor).toBe("rgba(255,42,42,1)");
    expect(harness.pendingFrames()).toBe(0);
  });

  it("changes live rain with the local date, independently of the animation clock", () => {
    const harness = canvasHarness();
    const rain = startCanvas2dRain(harness.canvas, "custom", 1, "#123456");
    rain.renderStatic(0);
    expect(harness.context.shadowColor).toBe("rgba(18,52,86,1)");

    vi.setSystemTime(new Date(2026, 1, 14));
    harness.runNextFrame(16);
    expect(harness.context.shadowColor).toBe("rgba(255,42,42,1)");

    vi.setSystemTime(new Date(2026, 2, 17));
    harness.runNextFrame(32);
    expect(harness.context.shadowColor).toBe("rgba(0,255,65,1)");

    vi.setSystemTime(new Date(2026, 1, 13));
    harness.runNextFrame(48);
    expect(harness.context.shadowColor).toBe("rgba(18,52,86,1)");
    expect(harness.pendingFrames()).toBe(1);
    rain.stop();
  });

  it("recolors a stopped static frame without starting animation", () => {
    const harness = canvasHarness();
    const rain = startCanvas2dRain(harness.canvas, "gold");
    rain.stop();
    rain.renderStatic(0);
    harness.fillText.mockClear();
    vi.setSystemTime(new Date(2026, 1, 14));
    rain.refreshTheme();
    expect(harness.fillText).toHaveBeenCalled();
    expect(harness.context.shadowColor).toBe("rgba(255,42,42,1)");
    expect(harness.context.shadowBlur).toBe(8);
    expect(harness.pendingFrames()).toBe(0);
  });

  it("does not advance positions, glyph RNG, or image scheduling when recoloring paused rain", () => {
    const harness = canvasHarness();
    const images = vi.fn(() => ({ frame: null, doc: DEFAULT_IMAGES, seed: 7 }));
    const rain = startCanvas2dRain(harness.canvas, "gold", 1, undefined, images);
    rain.renderStatic(0);
    rain.stop();
    images.mockClear();
    vi.mocked(harness.context.translate).mockClear();
    harness.fillText.mockClear();
    vi.setSystemTime(new Date(2026, 1, 14));
    rain.refreshTheme();
    const redPositions = vi.mocked(harness.context.translate).mock.calls.slice();
    const redGlyphs = harness.fillText.mock.calls.slice();
    vi.mocked(harness.context.translate).mockClear();
    harness.fillText.mockClear();
    vi.setSystemTime(new Date(2026, 2, 17));
    rain.refreshTheme();
    expect(vi.mocked(harness.context.translate).mock.calls).toEqual(redPositions);
    expect(harness.fillText.mock.calls).toEqual(redGlyphs);
    expect(images).not.toHaveBeenCalled();
    expect(harness.pendingFrames()).toBe(0);

    vi.setSystemTime(new Date(2026, 0, 1));
    rain.refreshTheme();
    rain.start();
    harness.fillText.mockClear();
    vi.mocked(harness.context.translate).mockClear();
    harness.runNextFrame(16);
    const resumedPositions = vi.mocked(harness.context.translate).mock.calls.slice();
    const resumedGlyphs = harness.fillText.mock.calls.slice();
    rain.stop();

    const control = canvasHarness();
    const controlRain = startCanvas2dRain(control.canvas, "gold");
    controlRain.renderStatic(0);
    control.fillText.mockClear();
    vi.mocked(control.context.translate).mockClear();
    control.runNextFrame(16);
    expect(vi.mocked(control.context.translate).mock.calls).toEqual(resumedPositions);
    expect(control.fillText.mock.calls).toEqual(resumedGlyphs);
    controlRain.stop();
  });

  it("scales glyph geometry to the backing-store ratio on high-density displays", () => {
    const harness = canvasHarness();
    Object.defineProperties(harness.canvas, {
      clientWidth: { value: 90 },
      clientHeight: { value: 90 },
    });

    const rain = startCanvas2dRain(harness.canvas, "classic", 1);
    harness.runNextFrame(0);

    expect(harness.context.font).toBe("36px monospace");
    rain.stop();
  });

  it("keeps requesting RAF while Wallpaper Engine gates skipped frames", () => {
    const harness = canvasHarness();
    const limiter = new WallpaperEngineFpsLimiter();
    limiter.setFps(30);
    const frameGate = vi.fn((nowMs: number) => limiter.sample(nowMs));

    const rain = startCanvas2dRain(
      harness.canvas,
      "classic",
      1,
      undefined,
      undefined,
      frameGate,
    );
    const initialPaints = harness.fillRect.mock.calls.length;
    expect(harness.pendingFrames()).toBe(1);

    harness.runNextFrame(0);
    expect(harness.fillRect).toHaveBeenCalledTimes(initialPaints + 1);
    expect(harness.pendingFrames()).toBe(1);

    harness.runNextFrame(16);
    expect(harness.fillRect).toHaveBeenCalledTimes(initialPaints + 1);
    expect(harness.pendingFrames()).toBe(1);

    harness.runNextFrame(34);
    expect(harness.fillRect).toHaveBeenCalledTimes(initialPaints + 2);
    expect(harness.pendingFrames()).toBe(1);
    expect(frameGate.mock.calls.map(([nowMs]) => nowMs)).toEqual([0, 16, 34]);

    rain.stop();
  });

  it("cancels a pending frame while paused and resumes with one fresh frame", () => {
    const harness = canvasHarness();
    const rain = startCanvas2dRain(harness.canvas);
    const initialPaints = harness.fillRect.mock.calls.length;
    const staleFrame = harness.runNextFrame(0);
    expect(harness.fillRect).toHaveBeenCalledTimes(initialPaints + 1);
    expect(harness.pendingFrames()).toBe(1);

    rain.stop();
    expect(harness.cancelFrame).toHaveBeenCalledOnce();
    expect(harness.pendingFrames()).toBe(0);

    // Browsers may already have dequeued a callback when pause arrives; it must be harmless.
    staleFrame(16);
    expect(harness.fillRect).toHaveBeenCalledTimes(initialPaints + 1);
    expect(harness.pendingFrames()).toBe(0);

    rain.start();
    rain.start();
    expect(harness.pendingFrames()).toBe(1);
    expect(harness.requestFrame).toHaveBeenCalledTimes(3);
    harness.runNextFrame(100);
    expect(harness.fillRect).toHaveBeenCalledTimes(initialPaints + 2);

    rain.stop();
  });

  it("paints warmed rain synchronously when animation is disabled before its first RAF", () => {
    const harness = canvasHarness();
    const rain = startCanvas2dRain(harness.canvas);
    rain.stop();

    expect(harness.pendingFrames()).toBe(0);
    expect(harness.fillText).not.toHaveBeenCalled();

    rain.renderStatic(0);

    expect(harness.pendingFrames()).toBe(0);
    expect(harness.fillText).toHaveBeenCalled();
    expect(harness.fillRect.mock.calls.length).toBeGreaterThan(100);
  });

  it("samples an image reveal only on the final paint of a static warm-up", () => {
    const harness = canvasHarness();
    const imageSource = vi.fn(() => ({ frame: null, doc: DEFAULT_IMAGES, seed: 7 }));
    const rain = startCanvas2dRain(
      harness.canvas,
      "classic",
      1,
      undefined,
      imageSource,
    );
    rain.stop();

    rain.renderStatic(1234);

    expect(imageSource).toHaveBeenCalledOnce();
    expect(imageSource).toHaveBeenCalledWith(1234);
  });
});

interface CanvasPaint {
  kind: "rect" | "text";
  x: number;
  y: number;
  width?: number;
  height?: number;
  text?: string;
  fillStyle: CanvasRenderingContext2D["fillStyle"];
  alpha: number;
  shadowBlur: number;
  composite: GlobalCompositeOperation;
}

function imageCanvasHarness() {
  const harness = canvasHarness();
  Object.defineProperties(harness.canvas, {
    width: { value: 72 }, height: { value: 72 },
    clientWidth: { value: 72 }, clientHeight: { value: 72 },
  });
  const ctx = harness.context;
  ctx.globalCompositeOperation = "source-over";
  const paints: CanvasPaint[] = [];
  let translation = { x: 0, y: 0 };
  const snapshot = () => ({
    fillStyle: ctx.fillStyle, globalAlpha: ctx.globalAlpha,
    shadowColor: ctx.shadowColor, shadowBlur: ctx.shadowBlur,
    globalCompositeOperation: ctx.globalCompositeOperation,
    font: ctx.font, textAlign: ctx.textAlign, textBaseline: ctx.textBaseline,
    ...translation,
  });
  const stack: ReturnType<typeof snapshot>[] = [];
  vi.mocked(ctx.save).mockImplementation(() => { stack.push(snapshot()); });
  vi.mocked(ctx.restore).mockImplementation(() => {
    const state = stack.pop();
    if (!state) throw new Error("Unbalanced canvas restore");
    const { x, y, ...properties } = state;
    Object.assign(ctx, properties);
    translation = { x, y };
  });
  vi.mocked(ctx.translate).mockImplementation((x, y) => {
    translation.x += x;
    translation.y += y;
  });
  harness.fillRect.mockImplementation((x: number, y: number, width: number, height: number) => {
    paints.push({ kind: "rect", x: x + translation.x, y: y + translation.y, width, height,
      fillStyle: ctx.fillStyle, alpha: ctx.globalAlpha, shadowBlur: ctx.shadowBlur,
      composite: ctx.globalCompositeOperation });
  });
  harness.fillText.mockImplementation((text: string, x: number, y: number) => {
    paints.push({ kind: "text", text, x: x + translation.x, y: y + translation.y,
      fillStyle: ctx.fillStyle, alpha: ctx.globalAlpha, shadowBlur: ctx.shadowBlur,
      composite: ctx.globalCompositeOperation });
  });
  return { ...harness, paints };
}

function imageRevealSource(values: number[], intensity = 1, scramble = 0): CanvasImageRevealSource {
  const mask = new Uint8Array(values);
  const image = { name: "Edges", width: 2, height: 2, data: encodeBase64Mask(mask) };
  return {
    frame: { image, mask, intensity, scramble, placementX: 0.5, placementY: 0.5,
      rainElapsed: 2.5, animationBucket: 45 },
    doc: { ...DEFAULT_IMAGES, enabled: true, images: [image], imageScale: 0.5, imagePlacementJitter: 0 },
    seed: 7,
  };
}

describe("Canvas2D image border extension", () => {
  beforeEach(() => {
    vi.spyOn(imageReveal, "imageFallingGate").mockReturnValue(1);
  });

  afterEach(() => { vi.restoreAllMocks(); });

  it("extends a uniform bright mask to every grid cell outside its fitted rectangle", () => {
    const harness = imageCanvasHarness();
    const rain = startCanvas2dRain(harness.canvas, "classic", 1, undefined,
      () => imageRevealSource([255, 255, 255, 255]));
    harness.runNextFrame(0);
    rain.stop();

    const glyphs = harness.paints.filter((paint) => paint.kind === "text");
    expect(glyphs).toHaveLength(16);
    for (const [x, y] of [[9, 9], [63, 9], [9, 63], [63, 63]]) {
      expect(glyphs).toContainEqual(expect.objectContaining({ x, y, text: "W", alpha: 0.48 }));
    }
    expect(harness.context.globalAlpha).toBe(1);
    expect(harness.context.shadowBlur).toBe(0);
  });

  it("uses each nearest corner's luminance for brightening or darkening surrounding rain", () => {
    const harness = imageCanvasHarness();
    const rain = startCanvas2dRain(harness.canvas, "classic", 1, undefined,
      () => imageRevealSource([0, 255, 255, 0]));
    harness.runNextFrame(0);
    rain.stop();

    for (const [x, y] of [[0, 0], [54, 54]]) {
      const darkened = harness.paints.find((paint) => paint.kind === "rect" && paint.x === x && paint.y === y && paint.width === 18);
      expect(darkened).toMatchObject({ height: 18, fillStyle: "rgba(13,2,8,1)", shadowBlur: 0, composite: "darken" });
      expect(darkened!.alpha).toBeCloseTo(0.46 * 0.48);
    }
    for (const [x, y] of [[63, 9], [9, 63]]) {
      expect(harness.paints).toContainEqual(expect.objectContaining({
        kind: "text", x, y, text: "W", fillStyle: "rgba(0,255,65,1)", composite: "source-over",
      }));
    }
  });

  it("preserves incoming compositing for bright glyphs after a dark cell", () => {
    const harness = imageCanvasHarness();
    harness.context.globalCompositeOperation = "screen";
    const rain = startCanvas2dRain(harness.canvas, "classic", 1, undefined,
      () => imageRevealSource([0, 255, 255, 0]));
    harness.runNextFrame(0);
    rain.stop();
    const glyphs = harness.paints.filter((paint) => paint.kind === "text");
    expect(glyphs.length).toBeGreaterThan(0);
    expect(glyphs.every((paint) => paint.composite === "screen")).toBe(true);
    expect(harness.context.globalCompositeOperation).toBe("screen");
  });

  it.each([0, 64, 96])("darkens a mask of luminance byte %i without adding glowing dots", (value) => {
    const harness = imageCanvasHarness();
    const rain = startCanvas2dRain(harness.canvas, "classic", 1, undefined,
      () => imageRevealSource([value, value, value, value]));
    harness.runNextFrame(0);
    rain.stop();

    const darkened = harness.paints.filter((paint) => paint.kind === "rect" && paint.width === 18);
    expect(darkened).toHaveLength(16);
    expect(darkened.every((paint) => paint.alpha > 0 && paint.alpha <= 0.46 * 0.48 && paint.shadowBlur === 0)).toBe(true);
    expect(harness.fillText).not.toHaveBeenCalled();
    expect(harness.context.globalAlpha).toBe(1);
    expect(harness.context.globalCompositeOperation).toBe("source-over");
  });

  it("lets a faint bright reveal fade below the ordinary glyph opacity floor", () => {
    const harness = imageCanvasHarness();
    const rain = startCanvas2dRain(harness.canvas, "classic", 1, undefined,
      () => imageRevealSource([255, 255, 255, 255], 0.05));
    harness.runNextFrame(0);
    rain.stop();
    const glyphs = harness.paints.filter((paint) => paint.kind === "text");
    expect(glyphs).toHaveLength(16);
    expect(glyphs.every((paint) => Math.abs(paint.alpha - 0.024) < 1e-10)).toBe(true);
  });

  it.each([0, 255])("retains intensity and scramble gates for luminance byte %i", (value) => {
    for (const [intensity, scramble] of [[0, 0], [1, 1]]) {
      const harness = imageCanvasHarness();
      const rain = startCanvas2dRain(harness.canvas, "classic", 1, undefined,
        () => imageRevealSource([value, value, value, value], intensity, scramble));
      harness.runNextFrame(0);
      rain.stop();
      expect(harness.paints.filter((paint) => paint.kind === "rect" && paint.width === 18)).toHaveLength(0);
      expect(harness.fillText).not.toHaveBeenCalled();
    }
  });

  it("leaves the rain's glyph, sparkle, and position streams unchanged after images stop", () => {
    const trace = (withImages: boolean) => {
      const harness = imageCanvasHarness();
      let active = true;
      const source = imageRevealSource([0, 255, 255, 0]);
      const rain = startCanvas2dRain(harness.canvas, "gold", 1, undefined,
        withImages ? () => ({ ...source, frame: active ? source.frame : null }) : undefined);
      for (let index = 0; index < 180; index++) harness.runNextFrame(index * 16);
      active = false;
      harness.fillText.mockClear();
      vi.mocked(harness.context.translate).mockClear();
      harness.runNextFrame(180 * 16);
      rain.stop();
      return { glyphs: harness.fillText.mock.calls, positions: vi.mocked(harness.context.translate).mock.calls };
    };
    expect(trace(true)).toEqual(trace(false));
  });

  it("recolors an active image on paused rain without resampling or advancing its frame", () => {
    const harness = imageCanvasHarness();
    const source = vi.fn(() => imageRevealSource([0, 255, 255, 0], 0.6));
    const rain = startCanvas2dRain(harness.canvas, "classic", 1, undefined, source);
    rain.renderStatic(0);
    rain.stop();
    source.mockClear();
    const signature = () => harness.paints.map(({ fillStyle: _fillStyle, ...paint }) => paint);

    harness.paints.length = 0;
    vi.setSystemTime(new Date(2026, 1, 14));
    rain.refreshTheme();
    const redFrame = signature();
    harness.paints.length = 0;
    vi.setSystemTime(new Date(2026, 2, 17));
    rain.refreshTheme();
    expect(signature()).toEqual(redFrame);
    expect(source).not.toHaveBeenCalled();
    expect(harness.pendingFrames()).toBe(0);
  });
});
