// Keep simulation speed tied to wall time when rendering falls below 15 FPS. Each RainSim update is
// still bounded to a small step for stable probabilities/motion, while a short series of substeps
// preserves the elapsed time instead of silently dropping it.

export const MAX_SIM_STEP_SECONDS = 1 / 15;
export const MAX_FRAME_CATCHUP_SECONDS = 0.25;

export interface SimulationStepPlan {
  steps: number;
  dt: number;
}

/** Split one rendered frame's elapsed time into stable simulation steps with bounded catch-up. */
export function simulationStepPlan(elapsedSeconds: number): SimulationStepPlan {
  if (!Number.isFinite(elapsedSeconds) || elapsedSeconds <= 0) return { steps: 0, dt: 0 };
  const elapsed = Math.min(elapsedSeconds, MAX_FRAME_CATCHUP_SECONDS);
  const steps = Math.ceil(elapsed / MAX_SIM_STEP_SECONDS);
  return { steps, dt: elapsed / steps };
}
