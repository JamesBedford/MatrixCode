import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { DEFAULT_IMAGES } from "../src/config/imagesStore.ts";
import { shouldSparkleGoldHead, startCanvas2dRain } from "../src/fallback/canvas2dRain.ts";
import { WallpaperEngineFpsLimiter } from "../src/platform/wallpaperEngine.ts";

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
