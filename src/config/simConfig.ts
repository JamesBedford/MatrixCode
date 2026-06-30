import type { SimConfig } from "../types.ts";

// Empirical tuning constants. These were chosen to match reference footage
// (Carl Newton's frame analysis + Rezmason/matrix) and are refined during the
// dedicated tuning pass. Keep every value named here so iteration is fast.
export const DEFAULT_SIM_CONFIG: SimConfig = {
  targetCellPx: 18,
  minSpeed: 3.5,
  speedRange: 8,
  // Per-second brightness multiplier. Lower = shorter, snappier trails.
  decayPerSecond: 0.08,
  // Per-second chance a lit (non-head) cell swaps glyph.
  mutationRate: 1.6,
  crossfadeDuration: 0.09,
  whiteHeadFraction: 0.2,
  respawnChance: 1.1,
  respawnDelayMin: 0.15,
  respawnDelayJitter: 2.6,
  startRowsAbove: 24,
  tailMargin: 36,
  globalSyncAmount: 0.35,
  globalSyncHz: 1.7,
};
