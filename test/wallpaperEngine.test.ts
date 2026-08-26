import { afterEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_CONTROLS } from "../src/config/controls.ts";
import { DEFAULT_INTRO } from "../src/config/introStore.ts";
import { DEFAULT_MESSAGES } from "../src/config/messagesStore.ts";
import {
  MAX_WALLPAPER_ENGINE_DIRECTORY_IMAGES,
  WALLPAPER_ENGINE_PROPERTY_DEFINITIONS,
  WallpaperEngineDirectoryIndex,
  WallpaperEngineFpsLimiter,
  WallpaperEnginePauseClock,
  createWallpaperEngineBridge,
  isWallpaperEngineImagePath,
  parseWallpaperEngineLocalDate,
  selectWallpaperEngineImageSources,
  wallpaperEngineColorToHex,
  wallpaperEngineFileUrl,
  type WallpaperEngineEvent,
  type WallpaperEngineWindow,
} from "../src/platform/wallpaperEngine.ts";

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

function property(value: unknown): { value: unknown } {
  return { value };
}

describe("Wallpaper Engine property contract", () => {
  it("expands every fixed slot with unique alphanumeric keys and orders", () => {
    const keys = WALLPAPER_ENGINE_PROPERTY_DEFINITIONS.map(({ key }) => key);
    const orders = WALLPAPER_ENGINE_PROPERTY_DEFINITIONS.map(({ order }) => order);
    expect(keys).toHaveLength(157);
    expect(new Set(keys).size).toBe(keys.length);
    expect(new Set(orders).size).toBe(orders.length);
    expect(keys.every((key) => /^[a-z0-9]+$/.test(key))).toBe(true);
    expect(keys.filter((key) => /^intro\d{2}/.test(key))).toHaveLength(48);
    expect(keys.filter((key) => /^message\d{2}/.test(key))).toHaveLength(24);
    expect(keys.filter((key) => /^moment\d{2}/.test(key))).toHaveLength(36);
  });

  it("maps manifest defaults to the current web defaults", () => {
    const host: WallpaperEngineWindow = {};
    const bridge = createWallpaperEngineBridge({ host });
    const config = bridge.configuration();

    expect(config.controls).toEqual(DEFAULT_CONTROLS);
    expect(config.intro).toEqual(DEFAULT_INTRO);
    expect(config.messages).toEqual(DEFAULT_MESSAGES);
    expect(config.countdown).toEqual({ targetMs: null, moments: [] });
    expect(config.userName).toBe("Neo");
    expect(config.images).toMatchObject({
      enabled: false,
      frequencyMs: 14000,
      persistenceMs: 12000,
      appearMs: 4500,
      disappearMs: 4500,
      imageScale: 0.72,
      imagePlacementJitter: 0.35,
      sources: [],
    });
  });

  it("queues the initial callback, then retains omitted values across deltas", () => {
    const host: WallpaperEngineWindow = {};
    const bridge = createWallpaperEngineBridge({ host });
    expect(host.wallpaperPropertyListener).toBe(bridge.listener);

    bridge.listener.applyUserProperties({
      rainspeed: property(2.25),
      viewername: property("Trinity"),
      customcolor: property("1 0.5 0"),
    });
    expect(bridge.hasInitialProperties()).toBe(true);
    expect(bridge.configuration().controls.speed).toBe(2.25);

    const events: WallpaperEngineEvent[] = [];
    bridge.attach((event) => events.push(event));
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ type: "properties", initial: true });
    if (events[0]?.type === "properties") {
      expect([...events[0].changedDomains].sort()).toEqual(["controls", "tokens"]);
      expect(events[0].configuration.controls.customColor).toBe("#FF8000");
      expect(events[0].configuration.userName).toBe("Trinity");
    }

    bridge.listener.applyUserProperties({ raindensity: property(7.5) });
    expect(bridge.configuration().controls).toMatchObject({ speed: 2.25, density: 7.5 });
    expect(events[1]).toMatchObject({ type: "properties", initial: false });
    if (events[1]?.type === "properties") {
      expect([...events[1].changedKeys]).toEqual(["raindensity"]);
      expect([...events[1].changedDomains]).toEqual(["controls"]);
    }
  });

  it("ignores unknown envelopes and sanitizes malformed or out-of-range values", () => {
    const bridge = createWallpaperEngineBridge({ host: {} });
    bridge.listener.applyUserProperties({
      unknown: property("ignored"),
      rainspeed: property(999),
      quality: property("impossible"),
      glyphmirror: property("yes"),
      customcolor: property("broken"),
    });
    expect(bridge.configuration().controls).toMatchObject({
      speed: 3,
      quality: "high",
      mirror: true,
      customColor: "#00FF41",
    });
    expect("unknown" in bridge.propertySnapshot()).toBe(false);
  });

  it("builds enabled slots in order and uses strict local countdown targets", () => {
    const bridge = createWallpaperEngineBridge({ host: {} });
    bridge.listener.applyUserProperties({
      intro01enabled: property(false),
      intro12enabled: property(true),
      intro12text: property("Last line"),
      intro12holdseconds: property(1.25),
      intro12pauseseconds: property(0.5),
      messagesenabled: property(true),
      message01text: property("   "),
      message12enabled: property(true),
      message12text: property("TWELVE"),
      messageshorizontalposition: property(0.75),
      messageshorizontaljitter: property(0.5),
      countdowntargetlocal: property("2030-06-01T12:30:15"),
      moment01enabled: property(true),
      moment01name: property(" launch:{} "),
      moment01targetlocal: property("2030-06-02T09:00"),
    });
    const config = bridge.configuration();
    expect(config.intro.lines.at(-1)).toEqual({ text: "Last line", holdMs: 1250, pauseMs: 500 });
    expect(config.messages.messages).toEqual([
      "THE MATRIX HAS YOU",
      "FOLLOW THE WHITE RABBIT",
      "{countup}",
      "TWELVE",
    ]);
    expect(config.messages).toMatchObject({
      horizontalPosition: 0.75,
      horizontalJitter: 0.5,
    });
    expect(config.countdown.targetMs).toBe(parseWallpaperEngineLocalDate("2030-06-01T12:30:15"));
    expect(config.countdown.moments).toEqual([
      { name: "launch", targetMs: parseWallpaperEngineLocalDate("2030-06-02T09:00") },
    ]);
  });

  it("waits for the initial payload and has a bounded timeout fallback", async () => {
    vi.useFakeTimers();
    const bridge = createWallpaperEngineBridge({ host: {} });
    const timedOut = bridge.waitForInitialProperties(1500);
    await vi.advanceTimersByTimeAsync(1500);
    await expect(timedOut).resolves.toBe(false);

    const received = bridge.waitForInitialProperties(1500);
    bridge.listener.applyUserProperties({});
    await expect(received).resolves.toBe(true);
  });

  it("detects the injected host API without relying on a user agent", () => {
    const bridge = createWallpaperEngineBridge({
      host: { wallpaperRequestRandomFileForProperty: () => undefined },
    });
    expect(bridge.isLikelyHosted()).toBe(true);
  });

  it("detects the generated package marker without relying on optional file APIs", () => {
    vi.stubGlobal("document", {
      querySelector: (selector: string) => selector.includes("matrixcode-wallpaper-engine") ? {} : null,
    });
    expect(createWallpaperEngineBridge({ host: {} }).isLikelyHosted()).toBe(true);
  });

  it("queues general and pause callbacks with a measured resume duration", () => {
    let now = 100;
    const bridge = createWallpaperEngineBridge({ host: {}, now: () => now });
    bridge.listener.applyGeneralProperties({ fps: 30 });
    bridge.listener.setPaused(true);

    const events: WallpaperEngineEvent[] = [];
    bridge.attach((event) => events.push(event));
    expect(events[0]).toEqual({ type: "general", fps: 30 });
    expect(events[1]).toMatchObject({ type: "pause", transition: { paused: true } });

    now = 650;
    bridge.listener.setPaused(false);
    expect(events[2]).toEqual({
      type: "pause",
      transition: {
        changed: true,
        paused: false,
        pausedDurationMs: 550,
        totalPausedMs: 550,
      },
    });
  });

  it("replays initial properties, directory contents and pause state in host order", () => {
    let now = 100;
    const bridge = createWallpaperEngineBridge({ host: {}, now: () => now });

    bridge.listener.applyUserProperties({
      rainspeed: property(1.75),
      imagesenabled: property(true),
    });
    bridge.listener.userDirectoryFilesAddedOrChanged("imagesdirectory", [
      "C:\\Matrix\\z.webp",
      "C:\\Matrix\\notes.txt",
      "C:\\Matrix\\a.png",
    ]);
    now = 250;
    bridge.listener.setPaused(true);

    expect(bridge.pauseClock.isPaused()).toBe(true);
    expect(bridge.configuration().images.sources.map(({ path }) => path)).toEqual([
      "C:\\Matrix\\a.png",
      "C:\\Matrix\\z.webp",
    ]);

    const events: WallpaperEngineEvent[] = [];
    bridge.attach((event) => events.push(event));

    expect(events.map(({ type }) => type)).toEqual(["properties", "directory", "pause"]);
    expect(events[0]).toMatchObject({ type: "properties", initial: true });
    if (events[0]?.type === "properties") {
      expect(events[0].configuration.controls.speed).toBe(1.75);
      expect(events[0].configuration.images.enabled).toBe(true);
      expect(events[0].configuration.images.sources).toEqual([]);
    }
    if (events[1]?.type === "directory") {
      expect(events[1].paths).toEqual(["C:\\Matrix\\a.png", "C:\\Matrix\\z.webp"]);
      expect(events[1].configuration.images.sources.map(({ path }) => path)).toEqual(events[1].paths);
    }
    expect(events[2]).toMatchObject({
      type: "pause",
      transition: { changed: true, paused: true, pausedDurationMs: 0 },
    });

    now = 725;
    bridge.listener.setPaused(false);
    expect(events[3]).toEqual({
      type: "pause",
      transition: {
        changed: true,
        paused: false,
        pausedDurationMs: 475,
        totalPausedMs: 475,
      },
    });
  });
});

describe("Wallpaper Engine image paths", () => {
  it("filters, de-duplicates, sorts and caps directory callbacks after validation", () => {
    const index = new WallpaperEngineDirectoryIndex();
    const files = Array.from({ length: 70 }, (_, value) =>
      `C:\\Images\\image-${String(69 - value).padStart(2, "0")}.PNG`
    );
    files.push("C:\\Images\\notes.txt", "C:\\IMAGES\\IMAGE-00.png");
    expect(index.addOrChange("somethingelse", files)).toBe(false);
    expect(index.addOrChange("imagesdirectory", files)).toBe(true);
    expect(index.paths()).toHaveLength(MAX_WALLPAPER_ENGINE_DIRECTORY_IMAGES);
    expect(index.paths()[0]).toBe("C:\\IMAGES\\IMAGE-00.png");
    expect(index.paths().at(-1)).toBe("C:\\Images\\image-63.PNG");
    expect(index.candidates()).toHaveLength(70);

    expect(index.remove("imagesdirectory", ["c:\\images\\image-00.png"])).toBe(true);
    expect(index.paths()).toHaveLength(MAX_WALLPAPER_ENGINE_DIRECTORY_IMAGES);
    expect(index.paths().at(-1)).toBe("C:\\Images\\image-64.PNG");
  });

  it("exposes the sorted directory as the image source pool", () => {
    const directory = ["C:\\pics\\z.webp", "C:\\pics\\a.jpg"];
    const sources = selectWallpaperEngineImageSources(directory);
    expect(sources.map(({ origin, path }) => `${origin}:${path}`)).toEqual([
      "directory:C:\\pics\\a.jpg",
      "directory:C:\\pics\\z.webp",
    ]);
  });

  it("supports WPE image extensions and produces escaped local URLs", () => {
    expect(isWallpaperEngineImagePath("C:\\A Folder\\雪 #1.webp")).toBe(true);
    expect(isWallpaperEngineImagePath("C:\\A Folder\\movie.webm")).toBe(false);
    expect(wallpaperEngineFileUrl("C:\\A Folder\\雪 #1.webp")).toBe(
      "file:///C:/A%20Folder/%E9%9B%AA%20%231.webp",
    );
    expect(wallpaperEngineFileUrl("\\\\server\\share\\a b.png")).toBe(
      "file://server/share/a%20b.png",
    );
  });
});

describe("Wallpaper Engine timing primitives", () => {
  it("limits RAF emissions while preserving skipped elapsed time", () => {
    const limiter = new WallpaperEngineFpsLimiter();
    limiter.setFps(30);
    expect(limiter.sample(0)).toEqual({ render: true, elapsedMs: 0 });
    expect(limiter.sample(16)).toEqual({ render: false, elapsedMs: 0 });
    expect(limiter.sample(34)).toEqual({ render: true, elapsedMs: 34 });
    expect(limiter.sample(50)).toEqual({ render: false, elapsedMs: 0 });
    expect(limiter.sample(68)).toEqual({ render: true, elapsedMs: 34 });

    limiter.setFps(0);
    expect(limiter.sample(84)).toEqual({ render: true, elapsedMs: 16 });
  });

  it("does not catch up time spent paused", () => {
    const limiter = new WallpaperEngineFpsLimiter();
    limiter.sample(0);
    limiter.setPaused(true, 10);
    expect(limiter.sample(1000)).toEqual({ render: false, elapsedMs: 0 });
    limiter.setPaused(false, 1000);
    expect(limiter.sample(1000)).toEqual({ render: true, elapsedMs: 0 });
    expect(limiter.sample(1016)).toEqual({ render: true, elapsedMs: 16 });
  });

  it("reports pause duration and app-relative active time", () => {
    const clock = new WallpaperEnginePauseClock();
    expect(clock.setPaused(true, 100)).toMatchObject({ changed: true, paused: true });
    expect(clock.activeTime(350)).toBe(100);
    expect(clock.setPaused(false, 600)).toEqual({
      changed: true,
      paused: false,
      pausedDurationMs: 500,
      totalPausedMs: 500,
    });
    expect(clock.activeTime(900)).toBe(400);
  });

  it("validates normalized colours and impossible local dates", () => {
    expect(wallpaperEngineColorToHex("0 1 0.2549019608")).toBe("#00FF41");
    expect(wallpaperEngineColorToHex("2 0 0")).toBeNull();
    expect(parseWallpaperEngineLocalDate("2030-02-30T12:00")).toBeNull();
    expect(parseWallpaperEngineLocalDate("2030/02/20 12:00")).toBeNull();
  });
});
