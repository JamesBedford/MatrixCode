import { describe, expect, it } from "vitest";
import {
  parsePanelHash,
  type MultiMonitorConfig,
} from "../src/multimonitor/multiMonitorFullscreen.ts";

const config: MultiMonitorConfig = {
  seed: 123,
  epoch: 456,
  warmupSeconds: 2.5,
  cell: 18,
  vCols: 200,
  vRows: 80,
  perDisplayMessages: true,
  slice: { colStart: 50, rowStart: 0, cols: 50, rows: 40 },
};

const encoded = encodeURIComponent(JSON.stringify(config));

describe("multi-monitor panel hash", () => {
  it("parses the renamed multimonitor key", () => {
    expect(parsePanelHash(`#multimonitor=${encoded}`)).toEqual(config);
  });

  it("accepts the legacy superfs key without exposing it as the new name", () => {
    expect(parsePanelHash(`#superfs=${encoded}`)).toEqual(config);
  });

  it("ignores unrelated or malformed hashes", () => {
    expect(parsePanelHash("#other=value")).toBeNull();
    expect(parsePanelHash("#multimonitor=not-json")).toBeNull();
  });
});
