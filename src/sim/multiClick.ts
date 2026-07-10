export type MultiClickAction = "wait" | "multiMonitor";

/** Advance the backdrop click sequence; the third click launches multi-monitor mode immediately. */
export function advanceMultiClick(currentCount: number): { count: number; action: MultiClickAction } {
  const count = currentCount + 1;
  return count >= 3 ? { count: 0, action: "multiMonitor" } : { count, action: "wait" };
}

/** Action to take when the multi-click window expires. */
export function settledMultiClickAction(count: number): "fullscreen" | "none" {
  return count === 2 ? "fullscreen" : "none";
}
