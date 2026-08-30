import { afterEach, describe, expect, it, vi } from "vitest";

import { effectivePresetName, getPreset, PRESET_NAMES } from "../src/config/colorPresets.ts";
import { ControlsStore } from "../src/config/controls.ts";
import type { PresetName } from "../src/types.ts";

afterEach(() => vi.useRealTimers());

describe("annual local-date color overrides", () => {
  const selections: PresetName[] = [...PRESET_NAMES, "custom"];

  it.each([2024, 2026, 2027, 2100])("uses Red on February 14 and Classic on March 17 in %i", (year) => {
    for (const selected of selections) {
      expect(effectivePresetName(selected, new Date(year, 1, 14))).toBe("red");
      expect(effectivePresetName(selected, new Date(year, 2, 17))).toBe("classic");
    }
  });

  it.each([
    [1, 14, "red"],
    [2, 17, "classic"],
  ] as const)("overrides the whole local day, only between its midnight boundaries (%i/%i)", (month, day, theme) => {
    for (const selected of selections) {
      expect(effectivePresetName(selected, new Date(2026, month, day - 1, 23, 59, 59, 999))).toBe(selected);
      expect(effectivePresetName(selected, new Date(2026, month, day, 0, 0, 0, 0))).toBe(theme);
      expect(effectivePresetName(selected, new Date(2026, month, day, 6, 59, 59))).toBe(theme);
      expect(effectivePresetName(selected, new Date(2026, month, day, 23, 59, 59, 999))).toBe(theme);
      expect(effectivePresetName(selected, new Date(2026, month, day + 1, 0, 0, 0, 0))).toBe(selected);
    }
  });

  it("reads local calendar components, never the UTC date", () => {
    // A local February 14 can still be February 13 in UTC (or February 15).
    const date = new Date("2026-02-13T23:30:00Z");
    vi.spyOn(date, "getMonth").mockReturnValue(1);
    vi.spyOn(date, "getDate").mockReturnValue(14);
    expect(date.getUTCDate()).toBe(13);
    expect(effectivePresetName("gold", date)).toBe("red");
  });

  it("uses the current wall clock on each call, including backward date changes", () => {
    vi.useFakeTimers();
    for (const [date, expected] of [
      [new Date(2026, 1, 13, 23, 59), "blue"],
      [new Date(2026, 1, 14), "red"],
      [new Date(2026, 1, 15), "blue"],
      [new Date(2026, 2, 17), "classic"],
      [new Date(2026, 1, 14), "red"],
      [new Date(2026, 0, 1), "blue"],
    ] as const) {
      vi.setSystemTime(date);
      expect(effectivePresetName("blue")).toBe(expected);
    }
  });

  it("leaves saved controls intact and restores the latest custom color afterward", () => {
    const store = new ControlsStore({
      initial: { preset: "blue" }, storage: null, readUrl: false, writeUrl: false, notifyNative: false,
    });
    const listener = vi.fn();
    store.subscribe(listener);
    expect(effectivePresetName(store.get().preset, new Date(2026, 1, 14))).toBe("red");
    expect(store.get().preset).toBe("blue");
    expect(listener).not.toHaveBeenCalled();

    store.set({ preset: "custom", customColor: "#123456" });
    const saved = store.get();
    expect(effectivePresetName(saved.preset, new Date(2026, 1, 14))).toBe("red");
    const restored = getPreset(effectivePresetName(saved.preset, new Date(2026, 1, 15)), saved.customColor);
    expect(restored).toEqual(getPreset("custom", "#123456"));
    expect(store.get()).toEqual(saved);
    expect(listener).toHaveBeenCalledOnce();
  });

  it("keeps raw palette lookup date-independent for editors and deterministic fixtures", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 1, 14));
    expect(getPreset("gold").name).toBe("gold");
    expect(getPreset("classic").name).toBe("classic");
  });
});
