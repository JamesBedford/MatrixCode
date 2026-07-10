import { describe, expect, it } from "vitest";
import {
  MAX_FRAME_CATCHUP_SECONDS,
  MAX_SIM_STEP_SECONDS,
  simulationStepPlan,
} from "../src/sim/frameSteps.ts";

describe("simulationStepPlan", () => {
  it("uses one exact step at normal frame rates", () => {
    expect(simulationStepPlan(1 / 60)).toEqual({ steps: 1, dt: 1 / 60 });
  });

  it("preserves wall time below 15 FPS by using bounded substeps", () => {
    const plan = simulationStepPlan(0.1); // 10 FPS
    expect(plan.steps).toBe(2);
    expect(plan.dt).toBeCloseTo(0.05);
    expect(plan.steps * plan.dt).toBeCloseTo(0.1);
    expect(plan.dt).toBeLessThanOrEqual(MAX_SIM_STEP_SECONDS);
  });

  it("caps catch-up after a long stall", () => {
    const plan = simulationStepPlan(10);
    expect(plan.steps * plan.dt).toBeCloseTo(MAX_FRAME_CATCHUP_SECONDS);
    expect(plan.dt).toBeLessThanOrEqual(MAX_SIM_STEP_SECONDS);
  });

  it("does not advance for invalid or non-positive elapsed time", () => {
    expect(simulationStepPlan(0)).toEqual({ steps: 0, dt: 0 });
    expect(simulationStepPlan(-1)).toEqual({ steps: 0, dt: 0 });
    expect(simulationStepPlan(Number.NaN)).toEqual({ steps: 0, dt: 0 });
  });
});
