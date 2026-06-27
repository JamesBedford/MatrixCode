import { describe, it, expect } from "vitest";
import {
  computeVirtualGrid,
  extractSlice,
  stepsToAdvance,
  type GridSlice,
  type ScreenRect,
} from "../src/super/superGrid.ts";

// cell=20 with 1920x1080 screens divides evenly (96 x 54) so we can assert
// exact column/row alignment without rounding noise.
const CELL = 20;
const W = 1920;
const H = 1080;
const COLS = W / CELL; // 96
const ROWS = H / CELL; // 54

// The example arrangement: one screen centered above three side-by-side screens.
//   [   top   ]
//   [b1][b2][b3]
// The top screen sits directly above b2 (same X range).
const SCREENS: ScreenRect[] = [
  { id: "top", left: W, top: 0, width: W, height: H },
  { id: "b1", left: 0, top: H, width: W, height: H },
  { id: "b2", left: W, top: H, width: W, height: H },
  { id: "b3", left: 2 * W, top: H, width: W, height: H },
];

describe("computeVirtualGrid", () => {
  const g = computeVirtualGrid(SCREENS, CELL);

  it("spans the bounding box of all screens", () => {
    expect(g.originX).toBe(0);
    expect(g.originY).toBe(0);
    expect(g.vCols).toBe(3 * COLS); // three screens wide
    expect(g.vRows).toBe(2 * ROWS); // two screens tall
  });

  it("aligns side-by-side screens into contiguous column ranges", () => {
    expect(g.slices.b1).toMatchObject({ colStart: 0, cols: COLS });
    expect(g.slices.b2).toMatchObject({ colStart: COLS, cols: COLS });
    expect(g.slices.b3).toMatchObject({ colStart: 2 * COLS, cols: COLS });
    // No gap / no overlap at the seams.
    expect(g.slices.b1!.colStart + g.slices.b1!.cols).toBe(g.slices.b2!.colStart);
    expect(g.slices.b2!.colStart + g.slices.b2!.cols).toBe(g.slices.b3!.colStart);
  });

  it("makes a column flow off the top screen onto the screen below it", () => {
    // The top screen shares b2's column range (vertical continuity).
    expect(g.slices.top!.colStart).toBe(g.slices.b2!.colStart);
    expect(g.slices.top!.cols).toBe(g.slices.b2!.cols);
    // The bottom row starts exactly where the top screen's rows end.
    expect(g.slices.top!.rowStart).toBe(0);
    expect(g.slices.top!.rowStart + g.slices.top!.rows).toBe(g.slices.b2!.rowStart);
  });

  it("keeps every slice within the virtual grid bounds", () => {
    for (const s of Object.values(g.slices)) {
      expect(s.colStart).toBeGreaterThanOrEqual(0);
      expect(s.rowStart).toBeGreaterThanOrEqual(0);
      expect(s.colStart + s.cols).toBeLessThanOrEqual(g.vCols);
      expect(s.rowStart + s.rows).toBeLessThanOrEqual(g.vRows);
    }
  });

  it("handles a single screen as the whole grid", () => {
    const one = computeVirtualGrid([{ id: "only", left: 0, top: 0, width: W, height: H }], CELL);
    expect(one.vCols).toBe(COLS);
    expect(one.vRows).toBe(ROWS);
    expect(one.slices.only).toEqual({ colStart: 0, rowStart: 0, cols: COLS, rows: ROWS });
  });

  it("uses negative virtual coordinates correctly (screen left of primary)", () => {
    const g2 = computeVirtualGrid(
      [
        { id: "left", left: -W, top: 0, width: W, height: H },
        { id: "primary", left: 0, top: 0, width: W, height: H },
      ],
      CELL,
    );
    expect(g2.originX).toBe(-W);
    expect(g2.slices.left).toMatchObject({ colStart: 0 });
    expect(g2.slices.primary).toMatchObject({ colStart: COLS });
  });
});

describe("extractSlice", () => {
  // Build a 4x3 (cols x rows) virtual grid where each cell's R,G bytes encode
  // its (col,row) so we can assert exactly which cells a slice pulls out.
  const VC = 4;
  const VR = 3;
  const src = new Uint8Array(VC * VR * 4);
  for (let r = 0; r < VR; r++) {
    for (let c = 0; c < VC; c++) {
      const o = (r * VC + c) * 4;
      src[o] = c; // R = col
      src[o + 1] = r; // G = row
    }
  }
  const cellRC = (buf: Uint8Array, lc: number, lx: number, ly: number): [number, number] => {
    const o = (ly * lc + lx) * 4;
    return [buf[o]!, buf[o + 1]!];
  };

  it("pulls out the correct sub-rectangle", () => {
    const slice: GridSlice = { colStart: 1, rowStart: 1, cols: 2, rows: 2 };
    const dst = extractSlice(src, VC, VR, slice, new Uint8Array(2 * 2 * 4));
    expect(cellRC(dst, 2, 0, 0)).toEqual([1, 1]);
    expect(cellRC(dst, 2, 1, 0)).toEqual([2, 1]);
    expect(cellRC(dst, 2, 0, 1)).toEqual([1, 2]);
    expect(cellRC(dst, 2, 1, 1)).toEqual([2, 2]);
  });

  it("keeps a shared column identical across vertically-stacked slices", () => {
    // A column shared by a top slice (rows 0..0) and a bottom slice (rows 1..2)
    // must read the same cells from the one virtual grid — that is the seam.
    const top = extractSlice(src, VC, VR, { colStart: 2, rowStart: 0, cols: 1, rows: 1 }, new Uint8Array(4));
    const bottom = extractSlice(src, VC, VR, { colStart: 2, rowStart: 1, cols: 1, rows: 2 }, new Uint8Array(2 * 4));
    expect(cellRC(top, 1, 0, 0)).toEqual([2, 0]); // virtual (col2,row0)
    expect(cellRC(bottom, 1, 0, 0)).toEqual([2, 1]); // continues at (col2,row1)
    expect(cellRC(bottom, 1, 0, 1)).toEqual([2, 2]); // then (col2,row2)
  });
});

describe("stepsToAdvance", () => {
  const dt = 1 / 60;

  it("returns 0 when already at or ahead of the target", () => {
    expect(stepsToAdvance(1, 1, dt, 8)).toBe(0);
    expect(stepsToAdvance(1, 2, dt, 8)).toBe(0);
  });

  it("advances by whole fixed steps toward the target", () => {
    expect(stepsToAdvance(3 * dt, 0, dt, 8)).toBe(3);
    // A partial step is not taken.
    expect(stepsToAdvance(3.9 * dt, 0, dt, 8)).toBe(3);
  });

  it("clamps to maxSteps so a stalled window catches up gradually", () => {
    expect(stepsToAdvance(100 * dt, 0, dt, 8)).toBe(8);
  });

  it("guards against a non-positive timestep", () => {
    expect(stepsToAdvance(1, 0, 0, 8)).toBe(0);
  });
});
