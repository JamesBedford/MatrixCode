import { afterEach, describe, expect, it, vi } from "vitest";

import { effectivePresetName, getPreset, PRESET_NAMES } from "../src/config/colorPresets.ts";
import { FullMoonDayCache, isFullMoonLocalDate } from "../src/sim/fullMoon.ts";
import { nextFullMoonMs } from "../src/sim/holidays.ts";
import type { PresetName } from "../src/types.ts";

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

const DAY_MS = 86400000;
const selections: PresetName[] = [...PRESET_NAMES, "custom"];

describe("full-moon color day", () => {
  it("covers each 2026 full-moon date using the existing offline lunar calculation", () => {
    // UTC dates checked against https://aa.usno.navy.mil/calculated/moon/phases?year=2026.
    const dates = [[1, 3], [2, 1], [3, 3], [4, 2], [5, 1], [5, 31], [6, 29],
      [7, 29], [8, 28], [9, 26], [10, 26], [11, 24], [12, 24]] as const;
    const cache = new FullMoonDayCache();
    for (const [month, day] of dates) {
      const start = Date.UTC(2026, month - 1, day);
      expect(cache.containsFullMoon(start - DAY_MS, start)).toBe(false);
      expect(cache.containsFullMoon(start, start + DAY_MS)).toBe(true);
      expect(cache.containsFullMoon(start + DAY_MS, start + 2 * DAY_MS)).toBe(false);
    }
  });

  it("uses White before and after the exact phase, then restores every selected palette", () => {
    const phase = nextFullMoonMs(Date.UTC(2026, 7, 20));
    const localPhase = new Date(phase);
    const start = new Date(localPhase.getFullYear(), localPhase.getMonth(), localPhase.getDate());
    const end = new Date(localPhase.getFullYear(), localPhase.getMonth(), localPhase.getDate() + 1);
    for (const selection of selections) {
      expect(effectivePresetName(selection, new Date(start.getTime() - 1))).toBe(selection);
      for (const instant of [start.getTime(), phase - 1, phase, phase + 1, end.getTime() - 1]) {
        expect(effectivePresetName(selection, new Date(instant))).toBe("white");
      }
      expect(effectivePresetName(selection, end)).toBe(selection);
    }
  });

  it("uses the local date rather than the UTC phase date, including timezone jumps", () => {
    const cache = new FullMoonDayCache();
    // The same August full moon is on Aug 27 in Los Angeles and Aug 28 in Tokyo.
    const westStart = Date.parse("2026-08-27T00:00:00-07:00");
    const eastStart = Date.parse("2026-08-28T00:00:00+09:00");
    expect(cache.containsFullMoon(westStart, westStart + DAY_MS)).toBe(true);
    expect(cache.containsFullMoon(eastStart, eastStart + DAY_MS)).toBe(true);
    expect(cache.containsFullMoon(westStart + DAY_MS, westStart + 2 * DAY_MS)).toBe(false);
    expect(cache.containsFullMoon(eastStart - DAY_MS, eastStart)).toBe(false);
  });

  it("refreshes after forward/backward clock changes and leaves custom colors untouched", () => {
    vi.useFakeTimers();
    const controls = Object.freeze({ preset: "custom" as const, customColor: "#123456" });
    const moon = new Date(nextFullMoonMs(Date.UTC(2026, 7, 20)));
    const tomorrow = new Date(moon.getFullYear(), moon.getMonth(), moon.getDate() + 1);
    for (const date of [moon, tomorrow, moon]) {
      vi.setSystemTime(date);
      const expected = date === moon ? "white" : "custom";
      expect(effectivePresetName(controls.preset)).toBe(expected);
      expect(getPreset(effectivePresetName(controls.preset), controls.customColor))
        .toEqual(getPreset(expected, "#123456"));
    }
    expect(controls).toEqual({ preset: "custom", customColor: "#123456" });
    expect(getPreset("gold").name).toBe("gold");
  });

  it("keeps fixed holiday colors when a full moon coincides", () => {
    vi.stubEnv("TZ", "UTC");
    for (const [year, month, day, color] of [[2033, 2, 14, "red"], [2041, 3, 17, "classic"]] as const) {
      const date = new Date(year, month - 1, day, 12);
      expect(isFullMoonLocalDate(date)).toBe(true);
      expect(effectivePresetName("blue", date)).toBe(color);
    }
  });

  it("updates the local-date result when the system timezone changes", () => {
    const instant = new Date("2026-08-28T08:00:00Z");
    vi.stubEnv("TZ", "Asia/Tokyo");
    expect(instant.getDate()).toBe(28);
    expect(isFullMoonLocalDate(instant)).toBe(true);
    vi.stubEnv("TZ", "America/Los_Angeles");
    expect(instant.getDate()).toBe(28);
    expect(isFullMoonLocalDate(instant)).toBe(false);
    vi.stubEnv("TZ", "Asia/Tokyo");
    expect(isFullMoonLocalDate(instant)).toBe(true);
  });

  it("covers full moons on real 23-hour and 25-hour days, including the extra final hour", () => {
    vi.stubEnv("TZ", "America/New_York");
    for (const [year, month, day, hours] of [[2017, 3, 12, 23], [2033, 11, 6, 25], [2060, 11, 7, 25]] as const) {
      const start = new Date(year, month - 1, day);
      const end = new Date(year, month - 1, day + 1);
      expect((end.getTime() - start.getTime()) / 3600000).toBe(hours);
      expect(isFullMoonLocalDate(start)).toBe(true);
      expect(isFullMoonLocalDate(new Date(end.getTime() - 1))).toBe(true);
      expect(isFullMoonLocalDate(end)).toBe(false);
    }
  });

  it("uses the first valid hour when DST skips midnight, and ends at tomorrow's midnight", () => {
    vi.stubEnv("TZ", "America/Santiago");
    const today = new Date(2025, 8, 7);
    const tomorrow = new Date(2025, 8, 8);
    expect(today.getHours()).toBe(1);
    expect((tomorrow.getTime() - today.getTime()) / 3600000).toBe(23);
    expect(isFullMoonLocalDate(today)).toBe(true);
    const phaseAfterToday = vi.fn(() => tomorrow.getTime() + 30 * 60000);
    expect(isFullMoonLocalDate(today, new FullMoonDayCache(phaseAfterToday))).toBe(false);
    expect(phaseAfterToday).toHaveBeenCalledWith(today.getTime() - 1);
  });

  it("does not confuse new moons with full moons", () => {
    expect(isFullMoonLocalDate(new Date(2026, 7, 12, 12))).toBe(false);
    expect(effectivePresetName("blue", new Date(2026, 7, 12, 12))).toBe("blue");
    expect(isFullMoonLocalDate(new Date(Number.NaN))).toBe(false);
  });
});

describe("bounded lunar-day cache", () => {
  it("includes a phase at the start and excludes the next midnight", () => {
    const phase = vi.fn(() => 1000);
    expect(new FullMoonDayCache(phase).containsFullMoon(1000, 2000)).toBe(true);
    expect(phase).toHaveBeenCalledWith(999);
    expect(new FullMoonDayCache(() => 2000).containsFullMoon(1000, 2000)).toBe(false);
  });

  it("calculates once per day and invalidates on either day boundary changing", () => {
    const phase = vi.fn(() => 2000);
    const cache = new FullMoonDayCache(phase);
    for (let frame = 0; frame < 120; frame++) expect(cache.containsFullMoon(1000, 2000)).toBe(false);
    expect(phase).toHaveBeenCalledOnce();
    expect(cache.containsFullMoon(1000, 3000)).toBe(true);
    expect(cache.containsFullMoon(2500, 3000)).toBe(false);
    expect(cache.containsFullMoon(1000, 2000)).toBe(false);
    expect(phase).toHaveBeenCalledTimes(4);
  });

  it("accepts 23-hour and 25-hour civil days without assuming 24 hours", () => {
    const start = Date.UTC(2026, 2, 8, 5);
    const twentyThreeHours = 23 * 3600000;
    expect(new FullMoonDayCache(() => start + twentyThreeHours - 1)
      .containsFullMoon(start, start + twentyThreeHours)).toBe(true);
    expect(new FullMoonDayCache(() => start + twentyThreeHours)
      .containsFullMoon(start, start + twentyThreeHours)).toBe(false);
    expect(new FullMoonDayCache(() => start + DAY_MS + 1)
      .containsFullMoon(start, start + 25 * 3600000)).toBe(true);
  });

  it("rejects invalid bounds without invoking the lunar solver", () => {
    const phase = vi.fn(() => 0);
    const cache = new FullMoonDayCache(phase);
    for (const [start, end] of [[NaN, 1], [0, Infinity], [2, 1], [1, 1]]) {
      expect(cache.containsFullMoon(start!, end!)).toBe(false);
    }
    expect(phase).not.toHaveBeenCalled();
  });
});
