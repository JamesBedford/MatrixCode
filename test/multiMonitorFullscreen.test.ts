import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  parsePanelHash,
  type MultiMonitorConfig,
} from "../src/multimonitor/multiMonitorFullscreen.ts";

const config: MultiMonitorConfig = {
  seed: 123,
  epoch: 456,
  warmupSeconds: 2.5,
  cell: 18,
  vCols: 200,
  vRows: 80,
  perDisplayMessages: true,
  slice: { colStart: 50, rowStart: 0, cols: 50, rows: 40 },
};

const encoded = encodeURIComponent(JSON.stringify(config));

function screen(left: number, top: number, width: number, height: number): Record<string, number> {
  return {
    left,
    top,
    width,
    height,
    availLeft: left,
    availTop: top,
    availWidth: width,
    availHeight: height,
  };
}

function installWindowManagementStubs(options?: {
  query?: () => Promise<{ state: PermissionState }>;
  open?: () => Window | null;
  screens?: Record<string, number>[];
  currentScreen?: Record<string, number>;
  isExtended?: boolean;
}) {
  const left = screen(0, 0, 1920, 1080);
  const right = screen(1920, 0, 1920, 1080);
  const screens = options?.screens ?? [left, right];
  const details = {
    screens,
    currentScreen: options?.currentScreen ?? screens[0]!,
  };
  const getScreenDetails = vi.fn(async () => details);
  const open = vi.fn(options?.open ?? (() => ({ closed: false }) as Window));
  const requestFullscreen = vi.fn(async () => undefined);
  const query = vi.fn(options?.query ?? (async () => ({ state: "granted" as PermissionState })));

  vi.stubGlobal("window", {
    getScreenDetails,
    open,
    screen: { isExtended: options?.isExtended ?? screens.length > 1 },
  });
  vi.stubGlobal("navigator", { permissions: { query } });
  vi.stubGlobal("location", { origin: "https://matrix.test", pathname: "/matrixcode.html", search: "" });

  return {
    left,
    right,
    getScreenDetails,
    open,
    query,
    requestFullscreen,
    rootEl: { requestFullscreen } as unknown as HTMLElement,
  };
}

function panelConfigFromOpenCall(call: unknown[]): MultiMonitorConfig {
  const url = String(call[0]);
  const hash = new URL(url).hash;
  const parsed = parsePanelHash(hash);
  expect(parsed).not.toBeNull();
  return parsed!;
}

describe("multi-monitor panel hash", () => {
  it("parses the renamed multimonitor key", () => {
    expect(parsePanelHash(`#multimonitor=${encoded}`)).toEqual(config);
  });

  it("accepts the legacy superfs key without exposing it as the new name", () => {
    expect(parsePanelHash(`#superfs=${encoded}`)).toEqual(config);
  });

  it("ignores unrelated or malformed hashes", () => {
    expect(parsePanelHash("#other=value")).toBeNull();
    expect(parsePanelHash("#multimonitor=not-json")).toBeNull();
  });
});

describe("multi-monitor session launch", () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("warms uncached screen details without opening panel windows from that click", async () => {
    const stubs = installWindowManagementStubs();
    const { startMultiMonitorSession } = await import("../src/multimonitor/multiMonitorFullscreen.ts");

    const first = await startMultiMonitorSession(stubs.rootEl, 18, 2.5, true);

    expect(first).toEqual({ kind: "needsRetry" });
    expect(stubs.getScreenDetails).toHaveBeenCalledTimes(1);
    expect(stubs.open).not.toHaveBeenCalled();
    expect(stubs.requestFullscreen).not.toHaveBeenCalled();

    const second = await startMultiMonitorSession(stubs.rootEl, 18, 2.5, true);

    expect(second.kind).toBe("multiMonitor");
    expect(stubs.getScreenDetails).toHaveBeenCalledTimes(1);
    expect(stubs.open).toHaveBeenCalledTimes(1);
    expect(stubs.requestFullscreen).toHaveBeenCalledTimes(1);
  });

  it("launches immediately when prefetch already cached granted screen details", async () => {
    const stubs = installWindowManagementStubs();
    const { prefetchScreens, startMultiMonitorSession } = await import(
      "../src/multimonitor/multiMonitorFullscreen.ts"
    );

    await prefetchScreens();
    const result = await startMultiMonitorSession(stubs.rootEl, 18, 2.5, false);

    expect(result.kind).toBe("multiMonitor");
    expect(stubs.query).toHaveBeenCalledTimes(1);
    expect(stubs.getScreenDetails).toHaveBeenCalledTimes(1);
    expect(stubs.open).toHaveBeenCalledTimes(1);
    expect(stubs.requestFullscreen).toHaveBeenCalledTimes(1);
  });

  it("marks the centremost screen as the only controls host", async () => {
    const left = screen(0, 0, 1920, 1080);
    const center = screen(1920, 0, 1920, 1080);
    const right = screen(3840, 0, 1920, 1080);
    const stubs = installWindowManagementStubs({
      screens: [left, center, right],
      currentScreen: left,
    });
    const { prefetchScreens, startMultiMonitorSession } = await import(
      "../src/multimonitor/multiMonitorFullscreen.ts"
    );

    await prefetchScreens();
    const result = await startMultiMonitorSession(stubs.rootEl, 18, 2.5, false);

    expect(result.kind).toBe("multiMonitor");
    if (result.kind !== "multiMonitor") return;
    expect(result.selfConfig.showControls).toBe(false);
    const panelConfigs = stubs.open.mock.calls.map(panelConfigFromOpenCall);
    expect(panelConfigs.map((cfg) => cfg.showControls)).toEqual([true, false]);
    expect(panelConfigs[0]!.screenId).toBe("s1");
    expect(panelConfigs[0]!.screens).toHaveLength(3);
  });

  it("refreshes a stale one-screen prefetch when macOS reports an extended display set", async () => {
    const stubs = installWindowManagementStubs({
      screens: [screen(0, 0, 1920, 1080)],
      isExtended: false,
    });
    const { prefetchScreens, startMultiMonitorSession } = await import(
      "../src/multimonitor/multiMonitorFullscreen.ts"
    );

    await prefetchScreens();
    expect(stubs.getScreenDetails).toHaveBeenCalledTimes(1);

    (window.screen as Screen & { isExtended?: boolean }).isExtended = true;
    stubs.getScreenDetails.mockResolvedValueOnce({
      screens: [stubs.left, stubs.right],
      currentScreen: stubs.left,
    });

    const first = await startMultiMonitorSession(stubs.rootEl, 18, 2.5, false);
    expect(first).toEqual({ kind: "needsRetry" });
    expect(stubs.getScreenDetails).toHaveBeenCalledTimes(2);

    const second = await startMultiMonitorSession(stubs.rootEl, 18, 2.5, false);
    expect(second.kind).toBe("multiMonitor");
    expect(stubs.open).toHaveBeenCalledTimes(1);
    expect(stubs.requestFullscreen).toHaveBeenCalledTimes(1);
  });

  it("falls back to click-to-warm behavior when the Permissions API cannot be queried", async () => {
    const stubs = installWindowManagementStubs({
      query: async () => {
        throw new TypeError("unsupported permission name");
      },
    });
    const { prefetchScreens, startMultiMonitorSession } = await import(
      "../src/multimonitor/multiMonitorFullscreen.ts"
    );

    await prefetchScreens();
    expect(stubs.getScreenDetails).not.toHaveBeenCalled();

    const result = await startMultiMonitorSession(stubs.rootEl, 18, 2.5, false);

    expect(result).toEqual({ kind: "needsRetry" });
    expect(stubs.open).not.toHaveBeenCalled();
    expect(stubs.requestFullscreen).not.toHaveBeenCalled();
  });

  it("does not fullscreen the controller when every panel window is blocked", async () => {
    const stubs = installWindowManagementStubs({ open: () => null });
    const { prefetchScreens, startMultiMonitorSession } = await import(
      "../src/multimonitor/multiMonitorFullscreen.ts"
    );

    await prefetchScreens();
    const result = await startMultiMonitorSession(stubs.rootEl, 18, 2.5, false);

    expect(result).toEqual({ kind: "popupsBlocked" });
    expect(stubs.open).toHaveBeenCalledTimes(1);
    expect(stubs.requestFullscreen).not.toHaveBeenCalled();
  });
});
