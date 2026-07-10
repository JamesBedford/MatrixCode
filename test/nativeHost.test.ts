import { afterEach, describe, expect, it, vi } from "vitest";
import {
  NATIVE_STORAGE_KEYS,
  bootstrapNativeHost,
  installNativeLifecycle,
  nativeMultiMonitorConfig,
  nativeStorageDidChange,
  sanitizeNativePayload,
  type NativeHostPayload,
} from "../src/platform/nativeHost.ts";
import { DEFAULT_CONTROLS } from "../src/config/controls.ts";

class MemoryStorage implements Storage {
  private values = new Map<string, string>();

  get length(): number {
    return this.values.size;
  }

  clear(): void {
    this.values.clear();
  }

  getItem(key: string): string | null {
    return this.values.get(key) ?? null;
  }

  key(index: number): string | null {
    return [...this.values.keys()][index] ?? null;
  }

  removeItem(key: string): void {
    this.values.delete(key);
  }

  setItem(key: string, value: string): void {
    this.values.set(key, String(value));
  }
}

const originalWindow = globalThis.window;
const originalDocument = globalThis.document;

function installGlobals(payload: NativeHostPayload, storage = new MemoryStorage()): MemoryStorage {
  const classes = new Set<string>();
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      __MATRIXCODE_NATIVE__: payload,
      localStorage: storage,
    },
  });
  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: {
      documentElement: {
        classList: {
          add: (...names: string[]) => names.forEach((name) => classes.add(name)),
          contains: (name: string) => classes.has(name),
        },
      },
    },
  });
  return storage;
}

afterEach(() => {
  Object.defineProperty(globalThis, "window", { configurable: true, value: originalWindow });
  Object.defineProperty(globalThis, "document", { configurable: true, value: originalDocument });
});

describe("native host payload", () => {
  it("accepts valid data while dropping unknown storage keys", () => {
    const result = sanitizeNativePayload({
      mode: "configuration",
      bootstrapId: "sheet-1",
      storage: { "mx-controls": "{}", unknown: "nope" },
    });

    expect(result).toEqual({
      mode: "configuration",
      bootstrapId: "sheet-1",
      storage: { "mx-controls": "{}" },
    });
  });

  it("rejects malformed top-level payloads and invalid sessions", () => {
    expect(sanitizeNativePayload(null)).toBeNull();
    expect(sanitizeNativePayload({ mode: "browser", bootstrapId: "x" })).toBeNull();
    expect(
      sanitizeNativePayload({
        mode: "screensaver",
        bootstrapId: "x",
        storage: {},
        session: { seed: 1, epoch: 2, warmupSeconds: 2.5, screens: [], currentScreenId: "missing" },
      }),
    ).toEqual({ mode: "screensaver", bootstrapId: "x", storage: {} });
  });

  it("seeds exactly the native storage whitelist once per sheet/session", () => {
    const payload: NativeHostPayload = {
      mode: "configuration",
      bootstrapId: "sheet-1",
      storage: { "mx-controls": "{\"density\":2}", "mx-user-name": "Trinity" },
    };
    const storage = installGlobals(payload);
    storage.setItem("mx-intro", "stale");
    storage.setItem("unrelated", "keep");

    expect(bootstrapNativeHost(storage)).toEqual(payload);
    expect(storage.getItem("mx-controls")).toBe("{\"density\":2}");
    expect(storage.getItem("mx-intro")).toBeNull();
    expect(storage.getItem("unrelated")).toBe("keep");
    expect(document.documentElement.classList.contains("mx-native-config")).toBe(true);

    storage.setItem("mx-controls", "edited");
    bootstrapNativeHost(storage);
    expect(storage.getItem("mx-controls")).toBe("edited");
    expect(NATIVE_STORAGE_KEYS).toHaveLength(6);
  });

  it("derives a tested virtual-grid slice from native screen geometry", () => {
    installGlobals({
      mode: "screensaver",
      bootstrapId: "run-1",
      storage: {},
      session: {
        seed: 123,
        epoch: 456,
        warmupSeconds: 2.5,
        currentScreenId: "right",
        screens: [
          { id: "left", left: 0, top: 0, width: 1920, height: 1080 },
          { id: "right", left: 1920, top: 0, width: 1920, height: 1080 },
        ],
      },
    });

    const config = nativeMultiMonitorConfig(DEFAULT_CONTROLS);
    expect(config).toMatchObject({
      seed: 123,
      epoch: 456,
      vCols: 214,
      vRows: 60,
      slice: { colStart: 106, rowStart: 0, cols: 108, rows: 60, originX: -12, originY: 0 },
    });
  });

  it("posts whitelisted storage changes and applies queued lifecycle state", () => {
    const postMessage = vi.fn();
    installGlobals({ mode: "screensaver", bootstrapId: "run-2", storage: {} });
    window.webkit = { messageHandlers: { matrixCodeStorage: { postMessage } } };

    nativeStorageDidChange("mx-intro-seen", "1");
    expect(postMessage).toHaveBeenCalledWith({ key: "mx-intro-seen", value: "1" });

    bootstrapNativeHost();
    window.__matrixCodeSetActive?.(false);
    const setActive = vi.fn();
    installNativeLifecycle(setActive);
    expect(setActive).toHaveBeenCalledWith(false);
  });
});
