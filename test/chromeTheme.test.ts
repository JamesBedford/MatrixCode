import { describe, expect, it } from "vitest";

import { chromeCustomProperties, getPreset } from "../src/config/colorPresets.ts";

describe("settings chrome colors", () => {
  it("uses the classic rain background for the default surfaces", () => {
    const chrome = chromeCustomProperties(getPreset("classic"));
    expect(chrome["--mx-bg"]).toBe("#0d0208");
    expect(chrome["--mx-panel"]).toBe("rgb(13 2 8 / 0.82)");
    expect(chrome["--mx-accent-rgb"]).toBe("0 255 65");
    expect(chrome["--mx-dim-rgb"]).toBe("0 143 17");
  });

  it("recolors surfaces and accents together for the selected theme", () => {
    const purple = chromeCustomProperties(getPreset("purple"));
    expect(purple["--mx-bg"]).toBe("#08020d");
    expect(purple["--mx-panel"]).toBe("rgb(8 2 13 / 0.82)");
    expect(purple["--mx-accent-rgb"]).toBe("178 59 255");
    expect(purple["--mx-dim-rgb"]).toBe("110 0 168");

    const custom = chromeCustomProperties(getPreset("custom", "#FF6600"));
    expect(custom["--mx-bg"]).toBe("#0d0500");
    expect(custom["--mx-accent-rgb"]).toBe("255 102 0");
  });
});
