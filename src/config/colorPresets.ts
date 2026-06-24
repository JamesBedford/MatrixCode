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

// Amber/blue are deliberately NOT film-accurate — offered as fun alternates.
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

const PRESETS: Record<PresetName, ColorPreset> = {
  classic: CLASSIC,
  amber: AMBER,
  blue: BLUE,
};

export function getPreset(name: PresetName): ColorPreset {
  return PRESETS[name] ?? CLASSIC;
}

export const PRESET_NAMES: PresetName[] = ["classic", "amber", "blue"];
