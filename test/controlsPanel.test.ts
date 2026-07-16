import { describe, expect, it } from "vitest";
import { controlsPanelOptionsForContext } from "../src/ui/controlsPanel.ts";

describe("controls panel display context", () => {
  it("provides the complete panel in ordinary mode", () => {
    expect(controlsPanelOptionsForContext(false, true)).toEqual({
      multiMonitor: false,
      introControls: true,
      documentEditors: true,
    });
  });

  it("provides the restricted exit panel on the multi-monitor controls screen", () => {
    expect(controlsPanelOptionsForContext(true, true)).toEqual({
      multiMonitor: true,
      introControls: false,
      documentEditors: false,
    });
  });

  it("mounts no panel on a non-controls multi-monitor controller", () => {
    expect(controlsPanelOptionsForContext(true, false)).toBeNull();
  });
});
