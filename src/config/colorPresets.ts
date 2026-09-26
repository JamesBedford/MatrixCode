import type { ColorPreset, PresetName } from "../types.ts";
import { hexToRgb } from "../util/math.ts";
import { ST_PATRICKS_DAY, VALENTINES_DAY } from "./holidayDates.ts";
import { isFullMoonLocalDate } from "../sim/fullMoon.ts";

export const DEFAULT_CUSTOM_COLOR = "#00FF41";

// Canonical Matrix palette (SchemeColor "Matrix Code Green"):
//   background #0D0208, tail #003B00, body #008F11, bright #00FF41, head white-green.
const CLASSIC: ColorPreset = {
  name: "classic",
  background: hexToRgb("#0D0208"),
  tail: hexToRgb("#003B00"),
  body: hexToRgb("#008F11"),
  bright: hexToRgb("#00FF41"),
  head: hexToRgb("#DEFFE4"),
};

// Everything below CLASSIC is deliberately NOT film-accurate — offered as fun alternates.
const AMBER: ColorPreset = {
  name: "amber",
  background: hexToRgb("#0A0600"),
  tail: hexToRgb("#3B1E00"),
  body: hexToRgb("#A85B00"),
  bright: hexToRgb("#FFB000"),
  head: hexToRgb("#FFF1C8"),
};

const ORANGE: ColorPreset = {
  name: "orange",
  background: hexToRgb("#0D0400"),
  tail: hexToRgb("#3B1200"),
  body: hexToRgb("#A84400"),
  bright: hexToRgb("#FF6A00"),
  head: hexToRgb("#FFE8D6"),
};

const BLUE: ColorPreset = {
  name: "blue",
  background: hexToRgb("#02060D"),
  tail: hexToRgb("#00263B"),
  body: hexToRgb("#0066A8"),
  bright: hexToRgb("#27D6FF"),
  head: hexToRgb("#E4FAFF"),
};

const GOLD: ColorPreset = {
  name: "gold",
  background: hexToRgb("#0C0800"),
  tail: hexToRgb("#4A3000"),
  body: hexToRgb("#B8860B"),
  bright: hexToRgb("#FFD700"),
  head: hexToRgb("#FFF4C2"),
};

const RED: ColorPreset = {
  name: "red",
  background: hexToRgb("#0D0202"),
  tail: hexToRgb("#3B0000"),
  body: hexToRgb("#A80008"),
  bright: hexToRgb("#FF2A2A"),
  head: hexToRgb("#FFE0E0"),
};

const PINK: ColorPreset = {
  name: "pink",
  background: hexToRgb("#0D0207"),
  tail: hexToRgb("#3B0022"),
  body: hexToRgb("#A80060"),
  bright: hexToRgb("#FF3DA0"),
  head: hexToRgb("#FFE2F1"),
};

const PURPLE: ColorPreset = {
  name: "purple",
  background: hexToRgb("#08020D"),
  tail: hexToRgb("#2A003B"),
  body: hexToRgb("#6E00A8"),
  bright: hexToRgb("#B23BFF"),
  head: hexToRgb("#F2E2FF"),
};

// Monochrome CRT phosphor.
const WHITE: ColorPreset = {
  name: "white",
  background: hexToRgb("#060606"),
  tail: hexToRgb("#2A2A2A"),
  body: hexToRgb("#8C8C8C"),
  bright: hexToRgb("#EDEDED"),
  head: hexToRgb("#FFFFFF"),
};

type StaticPresetName = Exclude<PresetName, "custom">;

const PRESETS: Record<StaticPresetName, ColorPreset> = {
  classic: CLASSIC,
  amber: AMBER,
  orange: ORANGE,
  gold: GOLD,
  red: RED,
  pink: PINK,
  purple: PURPLE,
  blue: BLUE,
  white: WHITE,
};

/** The named palettes that have a fixed, cross-platform five-stop definition. */
export const PRESET_NAMES = Object.keys(PRESETS) as StaticPresetName[];

/** Whether a value is a persisted palette selection, including the dynamic Custom palette. */
export function isPresetName(value: unknown): value is PresetName {
  return value === "custom" || (typeof value === "string" && PRESET_NAMES.includes(value as StaticPresetName));
}

/** Normalize a colour-picker value to the persisted #RRGGBB representation. */
export function sanitizeCustomColor(value: unknown): string | undefined {
  if (typeof value !== "string" || !/^#[0-9a-f]{6}$/i.test(value)) return undefined;
  return value.toUpperCase();
}

function scale(color: readonly [number, number, number], amount: number): [number, number, number] {
  return [color[0] * amount, color[1] * amount, color[2] * amount];
}

function lighten(color: readonly [number, number, number], amount: number): [number, number, number] {
  return [
    color[0] + (1 - color[0]) * amount,
    color[1] + (1 - color[1]) * amount,
    color[2] + (1 - color[2]) * amount,
  ];
}

/** Derive the rain's full brightness ramp from the user-selected display colour. */
export function customPreset(customColor: string = DEFAULT_CUSTOM_COLOR): ColorPreset {
  const bright = hexToRgb(sanitizeCustomColor(customColor) ?? DEFAULT_CUSTOM_COLOR);
  return {
    name: "custom",
    background: scale(bright, 0.05),
    tail: scale(bright, 0.23),
    body: scale(bright, 0.66),
    bright,
    head: lighten(bright, 0.88),
  };
}

export function getPreset(name: PresetName, customColor?: string): ColorPreset {
  if (name === "custom") return customPreset(customColor);
  return PRESETS[name] ?? CLASSIC;
}

function cssChannel(value: number): number {
  return Math.round(Math.min(1, Math.max(0, value)) * 255);
}

function cssChannels(color: readonly [number, number, number]): string {
  return `${cssChannel(color[0])} ${cssChannel(color[1])} ${cssChannel(color[2])}`;
}

function cssHex(color: readonly [number, number, number]): string {
  const byte = (value: number): string => cssChannel(value).toString(16).padStart(2, "0");
  return `#${byte(color[0])}${byte(color[1])}${byte(color[2])}`;
}

/**
 * CSS custom properties for the settings chrome. Surfaces use the rain palette's
 * background; accents use its bright and body stops. Defaults in styles.css are Classic.
 */
export function chromeCustomProperties(preset: ColorPreset): Record<string, string> {
  return {
    "--mx-accent-rgb": cssChannels(preset.bright),
    "--mx-dim-rgb": cssChannels(preset.body),
    "--mx-bg": cssHex(preset.background),
    "--mx-panel": `rgb(${cssChannels(preset.background)} / 0.82)`,
  };
}

type CalendarOverride = "valentines" | "patrick" | "fullMoon";

/** Fixed holidays take priority over a full moon. Null on an ordinary local day. */
function calendarOverride(localDate: Date): CalendarOverride | null {
  const month = localDate.getMonth() + 1;
  const day = localDate.getDate();
  if (month === VALENTINES_DAY.month && day === VALENTINES_DAY.day) return "valentines";
  if (month === ST_PATRICKS_DAY.month && day === ST_PATRICKS_DAY.day) return "patrick";
  if (isFullMoonLocalDate(localDate)) return "fullMoon";
  return null;
}

/** Local-calendar overrides affect presentation only; fixed holidays take priority over full moons. */
export function effectivePresetName(selected: PresetName, localDate = new Date()): PresetName {
  switch (calendarOverride(localDate)) {
    case "valentines": return "red";
    case "patrick": return "classic";
    case "fullMoon": return "white";
    default: return selected;
  }
}

/**
 * Settings copy for the active calendar override. Null on an ordinary day.
 * The saved theme is unchanged; this only names why the rain may differ from it.
 */
export function colorOverrideLabel(localDate = new Date()): string | null {
  switch (calendarOverride(localDate)) {
    case "valentines": return "Overridden by Valentine's Day";
    case "patrick": return "Overridden by St. Patrick's Day";
    case "fullMoon": return "Overridden by full moon";
    default: return null;
  }
}
