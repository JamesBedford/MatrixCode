import type { ColorPreset, PresetName } from "../types.ts";
import { hexToRgb } from "../util/math.ts";

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
  background: hexToRgb("#0D0B00"),
  tail: hexToRgb("#3B3300"),
  body: hexToRgb("#A89000"),
  bright: hexToRgb("#FFE21F"),
  head: hexToRgb("#FFFBD6"),
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

const PRESETS: Record<PresetName, ColorPreset> = {
  classic: CLASSIC,
  amber: AMBER,
  gold: GOLD,
  red: RED,
  pink: PINK,
  purple: PURPLE,
  blue: BLUE,
  white: WHITE,
};

export function getPreset(name: PresetName): ColorPreset {
  return PRESETS[name] ?? CLASSIC;
}

export const PRESET_NAMES: PresetName[] = Object.keys(PRESETS) as PresetName[];
