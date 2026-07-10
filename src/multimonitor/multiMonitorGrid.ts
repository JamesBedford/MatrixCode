// Pure, DOM-free geometry for multi-monitor mode: map a set of physical
// screens (in the Window Management API's unified virtual coordinate space) onto
// one shared rain grid, and give each screen the sub-rectangle it should render.
// Because screens above/below share an X range, a column that flows off the
// bottom of one screen continues onto the screen below it; side-by-side screens
// occupy adjacent column ranges that line up. Kept side-effect-free so it is
// fully unit-testable.

/** A screen's rectangle in the OS virtual coordinate space (CSS pixels). */
export interface ScreenRect {
  id: string;
  left: number;
  top: number;
  width: number;
  height: number;
}

/** The sub-rectangle of the virtual grid that one screen renders. */
export interface GridSlice {
  colStart: number;
  rowStart: number;
  cols: number;
  rows: number;
  /** Local CSS-pixel position of colStart/rowStart; non-positive when the first cell is clipped. */
  originX?: number;
  originY?: number;
}

export interface VirtualGrid {
  /** Top-left of the bounding box of all screens, in virtual CSS pixels. */
  originX: number;
  originY: number;
  /** Cell size in CSS pixels (uniform across every screen, so seams align). */
  cell: number;
  /** Dimensions of the full virtual grid spanning the screen bounding box. */
  vCols: number;
  vRows: number;
  /** Per-screen slice, keyed by ScreenRect.id. */
  slices: Record<string, GridSlice>;
}

/**
 * Build the shared virtual grid and each screen's slice. The origin is the
 * top-left of the screens' bounding box; the grid spans to the far edges. Cell
 * boundaries are shared by all screens (same `cell`), so adjacent screens align
 * to within sub-cell rounding.
 */
export function computeVirtualGrid(screens: ScreenRect[], cell: number): VirtualGrid {
  let minL = Infinity;
  let minT = Infinity;
  let maxR = -Infinity;
  let maxB = -Infinity;
  for (const s of screens) {
    minL = Math.min(minL, s.left);
    minT = Math.min(minT, s.top);
    maxR = Math.max(maxR, s.left + s.width);
    maxB = Math.max(maxB, s.top + s.height);
  }
  const originX = minL;
  const originY = minT;
  const safeCell = Math.max(Number.EPSILON, cell);
  const vCols = Math.max(1, Math.ceil((maxR - minL) / safeCell));
  const vRows = Math.max(1, Math.ceil((maxB - minT) / safeCell));

  const slices: Record<string, GridSlice> = {};
  for (const s of screens) {
    const offsetX = s.left - originX;
    const offsetY = s.top - originY;
    const colStart = Math.floor(offsetX / safeCell);
    const rowStart = Math.floor(offsetY / safeCell);
    const localOriginX = colStart * safeCell - offsetX;
    const localOriginY = rowStart * safeCell - offsetY;
    slices[s.id] = {
      colStart,
      rowStart,
      cols: Math.max(1, Math.ceil((s.width - localOriginX) / safeCell)),
      rows: Math.max(1, Math.ceil((s.height - localOriginY) / safeCell)),
      originX: localOriginX,
      originY: localOriginY,
    };
  }
  return { originX, originY, cell: safeCell, vCols, vRows, slices };
}

/**
 * Copy one screen's sub-rectangle out of the full virtual-grid RGBA8 state into
 * `dst` (length must be slice.cols * slice.rows * 4). Rows/columns are clamped to
 * the grid bounds; cells outside the grid are left untouched (dark). Returns
 * `dst` for convenience.
 */
export function extractSlice(
  src: Uint8Array,
  vCols: number,
  vRows: number,
  slice: GridSlice,
  dst: Uint8Array,
): Uint8Array {
  const { colStart, rowStart, cols: lc, rows: lr } = slice;
  const run = Math.max(0, Math.min(lc, vCols - colStart)) * 4;
  for (let ly = 0; ly < lr; ly++) {
    const sy = rowStart + ly;
    if (sy < 0 || sy >= vRows || run === 0) continue;
    const sOff = (sy * vCols + colStart) * 4;
    dst.set(src.subarray(sOff, sOff + run), ly * lc * 4);
  }
  return dst;
}

/**
 * Fixed-timestep step count for a shared wall-clock: how many `fixedDt` steps
 * advance the sim from `simClockSec` toward `targetSec`, capped at `maxSteps` so
 * a stalled window catches up gradually instead of freezing. Returns 0 when
 * already at or ahead of the target.
 */
export function stepsToAdvance(
  targetSec: number,
  simClockSec: number,
  fixedDt: number,
  maxSteps: number,
): number {
  if (fixedDt <= 0) return 0;
  const behind = targetSec - simClockSec;
  if (behind <= 0) return 0;
  return Math.min(Math.floor(behind / fixedDt), maxSteps);
}
