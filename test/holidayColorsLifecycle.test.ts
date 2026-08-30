import { afterEach, describe, expect, it, vi } from "vitest";

import { mountMatrixRain, type MatrixRainHandle } from "../src/app.ts";
import { startCanvas2dRain } from "../src/fallback/canvas2dRain.ts";
import { createWallpaperEngineBridge } from "../src/platform/wallpaperEngine.ts";

vi.mock("../src/fallback/canvas2dRain.ts", () => ({ startCanvas2dRain: vi.fn() }));

let app: MatrixRainHandle | undefined;
afterEach(() => {
  app?.destroy();
  app = undefined;
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

function harness(reducedMotion = false) {
  vi.useFakeTimers();
  const fallback = { start: vi.fn(), stop: vi.fn(), renderStatic: vi.fn(), refreshTheme: vi.fn() };
  vi.mocked(startCanvas2dRain).mockReturnValue(fallback);
  const setProperty = vi.fn();
  const makeElement = () => ({
    classList: { add: vi.fn(), remove: vi.fn() },
    appendChild: vi.fn(), remove: vi.fn(), getContext: () => null,
    clientWidth: 180, clientHeight: 180,
  });
  const icon = { href: "", rel: "icon", type: "" };
  const document = Object.assign(new EventTarget(), {
    hidden: false,
    documentElement: { style: { setProperty }, classList: { add: vi.fn(), remove: vi.fn() } },
    createElement: makeElement,
    querySelector: () => icon,
  });
  const media = Object.assign(new EventTarget(), { matches: reducedMotion });
  vi.stubGlobal("document", document);
  vi.stubGlobal("window", {
    setInterval, clearInterval, devicePixelRatio: 1, matchMedia: () => media,
  });
  vi.stubGlobal("location", { search: "", pathname: "/", hash: "" });
  vi.stubGlobal("ResizeObserver", class { observe() {} disconnect() {} });
  return { document, container: makeElement() as unknown as HTMLElement, fallback, setProperty, icon };
}

describe("mounted holiday color lifecycle", () => {
  it("updates reduced-motion browser rain at midnight and cleans up the date watcher", async () => {
    const view = harness(true);
    vi.setSystemTime(new Date(2026, 1, 13, 23, 59, 59));
    app = await mountMatrixRain(view.container, { preset: "blue" });
    expect(app.controls.get().preset).toBe("blue");
    view.fallback.renderStatic.mockClear();
    vi.advanceTimersByTime(1000);
    expect(view.setProperty).toHaveBeenLastCalledWith("--mx-dim-rgb", "168 0 8");
    expect(decodeURIComponent(view.icon.href)).toContain("#ff2a2a");
    expect(view.fallback.refreshTheme).toHaveBeenCalledOnce();
    expect(view.fallback.renderStatic).not.toHaveBeenCalled();
    expect(app.controls.get().preset).toBe("blue");

    app.destroy();
    app = undefined;
    expect(vi.getTimerCount()).toBe(0);
    view.fallback.refreshTheme.mockClear();
    view.document.dispatchEvent(new Event("visibilitychange"));
    expect(view.fallback.refreshTheme).not.toHaveBeenCalled();
  });

  it("restores latest Wallpaper Engine controls after a holiday while its timeline stays paused", async () => {
    const view = harness();
    vi.setSystemTime(new Date(2026, 2, 17));
    const bridge = createWallpaperEngineBridge({ host: {} });
    bridge.listener.setPaused(true);
    app = await mountMatrixRain(view.container, undefined, { wallpaperEngine: bridge });
    expect(view.setProperty).toHaveBeenCalledWith("--mx-accent-rgb", "0 255 65");
    // Host property changes flow through the ordinary controls subscription.
    bridge.listener.applyUserProperties({
      colorpreset: { value: "custom" },
      customcolor: { value: `${18 / 255} ${52 / 255} ${86 / 255}` },
    });
    expect(app.controls.get().preset).toBe("custom");
    expect(view.setProperty).toHaveBeenLastCalledWith("--mx-dim-rgb", "0 143 17");
    view.fallback.renderStatic.mockClear();
    vi.setSystemTime(new Date(2026, 2, 18));
    vi.advanceTimersByTime(1000);
    expect(view.setProperty).toHaveBeenCalledWith("--mx-accent-rgb", "18 52 86");
    expect(view.fallback.refreshTheme).toHaveBeenCalledOnce();
    expect(view.fallback.renderStatic).not.toHaveBeenCalled();
    expect(bridge.pauseClock.isPaused()).toBe(true);
    expect(app.controls.get()).toMatchObject({ preset: "custom", customColor: "#123456" });
    expect(bridge.configuration().controls).toMatchObject({ preset: "custom", customColor: "#123456" });
  });

  it("refreshes a hidden static browser view immediately when it becomes visible", async () => {
    const view = harness(true);
    vi.setSystemTime(new Date(2026, 1, 13));
    app = await mountMatrixRain(view.container, { preset: "blue" });
    view.document.hidden = true;
    view.document.dispatchEvent(new Event("visibilitychange"));
    vi.setSystemTime(new Date(2026, 1, 14));
    vi.advanceTimersByTime(2000);
    expect(view.fallback.refreshTheme).not.toHaveBeenCalled();
    view.document.hidden = false;
    view.document.dispatchEvent(new Event("visibilitychange"));
    expect(view.fallback.refreshTheme).toHaveBeenCalledOnce();
    expect(view.setProperty).toHaveBeenCalledWith("--mx-accent-rgb", "255 42 42");
  });
});
