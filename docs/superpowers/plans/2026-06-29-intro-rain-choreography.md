# Intro Rain Choreography Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the intro editor control whether the Matrix rain falls during the intro or waits until after it (with a configurable post-intro delay), and how long the rain takes to linearly ramp its density up to full once it starts.

**Architecture:** Three new fields on `IntroScript`, a pure `densityRampFactor` helper, and a `RainSim.reset()` (empty the grid), orchestrated by `app.ts` — which already owns the RAF loop and intro lifecycle. The headless sim stays intro-agnostic; the loop gates updates on a rain-start timestamp and scales the density it passes to `sim.update`.

**Tech Stack:** TypeScript, Vite (`vite-plugin-singlefile`), Vitest (Node env, no DOM), vanilla DOM, WebGL2.

## Global Constraints

- No new dependencies — vanilla DOM, matching existing files.
- Tests run in a Node environment with no DOM; only pure logic is unit-tested. DOM/UI classes (`introEditor.ts`) and integration glue (`app.ts`) are verified by `npx tsc --noEmit`, the existing suite, and a Playwright smoke (controller-run).
- The choreography applies ONLY when the intro plays (first visit, Replay, Preview). Repeat/no-intro visits and `prefers-reduced-motion` behave exactly as today: warmed-up, full-density rain immediately.
- The ramp affects **density only** (`speed` unchanged) and is **linear**.
- Defaults reproduce today's intro exactly: `rainDuringIntro: true`, `postIntroDelayMs: 0`, `rampUpMs: 0`.
- Durations are shown in the modal in **seconds** (step 0.1), stored as **milliseconds**.
- localStorage key stays `mx-intro`. Existing stored scripts lack the new fields; `sanitizeIntro` must fill the defaults.
- The existing P-key play/pause (`userPaused`) and super-fullscreen paths must keep working — do not alter them.
- After changes: `npx tsc --noEmit` clean and `npm test` green.

---

### Task 1: `RainSim.reset()`

**Files:**
- Modify: `src/sim/rainSim.ts`
- Test: `test/rainSim.test.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces: `RainSim.reset(): void` — returns the sim to its empty initial state (as just after construction, before any `update`).

- [ ] **Step 1: Write the failing tests**

Append this `describe` block to `test/rainSim.test.ts` (after the existing `describe("RainSim", ...)` block, before the final closing of the file):

```ts
describe("RainSim.reset", () => {
  it("empties the grid (every state byte 0)", () => {
    const sim = makeSim(20, 30);
    sim.warmUp(CONTROLS, 2);
    let litBefore = 0;
    for (let i = 0; i < sim.cols * sim.rows; i++) if (sim.state[i * 4 + 1]! > 0) litBefore++;
    expect(litBefore).toBeGreaterThan(0); // precondition: rain is present

    sim.reset();
    expect(Array.from(sim.state).every((b) => b === 0)).toBe(true);
  });

  it("matches a freshly constructed sim's empty state", () => {
    const a = makeSim(16, 24, 999);
    a.warmUp(CONTROLS, 1);
    a.reset();
    const fresh = makeSim(16, 24, 999);
    expect(Array.from(a.state)).toEqual(Array.from(fresh.state));
  });

  it("resumes producing rain after reset", () => {
    const sim = makeSim(20, 30);
    sim.warmUp(CONTROLS, 2);
    sim.reset();
    sim.warmUp(CONTROLS, 2);
    let lit = 0;
    for (let i = 0; i < sim.cols * sim.rows; i++) if (sim.state[i * 4 + 1]! > 0) lit++;
    expect(lit).toBeGreaterThan(0);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx vitest run test/rainSim.test.ts -t "RainSim.reset"`
Expected: FAIL — `sim.reset is not a function`.

- [ ] **Step 3: Implement `reset()`**

In `src/sim/rainSim.ts`, add this method immediately after the `warmUp(...)` method (right before `update(...)`):

```ts
  /** Return the sim to its empty initial state (as just after construction, before any update). */
  reset(): void {
    this.bright.fill(0);
    this.glyphNew.fill(0);
    this.glyphOld.fill(0);
    this.phase.fill(0);
    this.state.fill(0);
    this.time = 0;
    this.seedColumns(0, this.cols); // deactivate every column + restagger respawn timers
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npx vitest run test/rainSim.test.ts`
Expected: PASS (all RainSim tests, including the new reset block).

- [ ] **Step 5: Typecheck**

Run: `npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add src/sim/rainSim.ts test/rainSim.test.ts
git commit -m "Add RainSim.reset() to empty the grid"
```

---

### Task 2: `densityRampFactor` pure helper

**Files:**
- Create: `src/sim/introRain.ts`
- Test: `test/introRain.test.ts`

**Interfaces:**
- Consumes: `clamp` from `src/util/math.ts`.
- Produces: `densityRampFactor(nowMs: number, rainStartAtMs: number, rampUpMs: number): number` — density multiplier in [0,1].

- [ ] **Step 1: Write the failing test**

Create `test/introRain.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { densityRampFactor } from "../src/sim/introRain.ts";

describe("densityRampFactor", () => {
  it("is 0 before the rain starts", () => {
    expect(densityRampFactor(100, 200, 5000)).toBe(0);
  });

  it("is 0 exactly at the start when there is a ramp", () => {
    expect(densityRampFactor(200, 200, 1000)).toBe(0);
  });

  it("is 1 immediately when there is no ramp", () => {
    expect(densityRampFactor(200, 200, 0)).toBe(1);
    expect(densityRampFactor(5000, 200, 0)).toBe(1);
  });

  it("is linear across the ramp", () => {
    expect(densityRampFactor(200 + 250, 200, 1000)).toBeCloseTo(0.25, 6);
    expect(densityRampFactor(200 + 500, 200, 1000)).toBeCloseTo(0.5, 6);
  });

  it("clamps to 1 past the end of the ramp", () => {
    expect(densityRampFactor(200 + 2000, 200, 1000)).toBe(1);
  });

  it("treats a -Infinity start as already running at full", () => {
    expect(densityRampFactor(0, Number.NEGATIVE_INFINITY, 0)).toBe(1);
    expect(densityRampFactor(0, Number.NEGATIVE_INFINITY, 5000)).toBe(1);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run test/introRain.test.ts`
Expected: FAIL — `Cannot find module '../src/sim/introRain.ts'`.

- [ ] **Step 3: Write the implementation**

Create `src/sim/introRain.ts`:

```ts
import { clamp } from "../util/math.ts";

/**
 * Density multiplier (0..1) for the rain at `nowMs`, given when it starts
 * (`rainStartAtMs`) and how long it linearly ramps up (`rampUpMs`).
 * Returns 0 before the start, 1 once the ramp completes (or immediately when
 * `rampUpMs <= 0`). A `rainStartAtMs` of -Infinity means "already running".
 */
export function densityRampFactor(nowMs: number, rainStartAtMs: number, rampUpMs: number): number {
  if (nowMs < rainStartAtMs) return 0;
  if (rampUpMs <= 0) return 1;
  return clamp((nowMs - rainStartAtMs) / rampUpMs, 0, 1);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx vitest run test/introRain.test.ts`
Expected: PASS.

- [ ] **Step 5: Typecheck**

Run: `npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add src/sim/introRain.ts test/introRain.test.ts
git commit -m "Add densityRampFactor helper for intro rain ramp-up"
```

---

### Task 3: `IntroScript` rain fields + sanitize

**Files:**
- Modify: `src/config/introStore.ts`
- Test: `test/introStore.test.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces: `IntroScript` gains `rainDuringIntro: boolean`, `postIntroDelayMs: number`, `rampUpMs: number`. `DEFAULT_INTRO` and `sanitizeIntro` carry them. `cloneIntro` and `toTypeConfig` are unchanged (cloneIntro already spreads top-level scalars; toTypeConfig ignores the new fields).

- [ ] **Step 1: Update the tests (TDD — these encode the new behavior)**

In `test/introStore.test.ts`, make these edits:

(a) The "persists across instances (round-trip)" test currently sets a script without the new fields. Replace its `a.set({...})` call and assertions with:

```ts
    const a = new IntroStore();
    a.set({ lines: [{ text: "hi {name}", holdMs: 1000, pauseMs: 500 }], charMs: 50, startDelayMs: 0, fadeOutMs: 0, rainDuringIntro: false, postIntroDelayMs: 1500, rampUpMs: 8000 });
    const b = new IntroStore();
    expect(b.get().lines).toEqual([{ text: "hi {name}", holdMs: 1000, pauseMs: 500 }]);
    expect(b.get().charMs).toBe(50);
    expect(b.get().rainDuringIntro).toBe(false);
    expect(b.get().postIntroDelayMs).toBe(1500);
    expect(b.get().rampUpMs).toBe(8000);
```

(b) The "reset clears storage and returns defaults" test sets a script; add the three fields to its `s.set({...})` literal so it type-checks:

```ts
    s.set({ lines: [{ text: "x", holdMs: 1, pauseMs: 1 }], charMs: 50, startDelayMs: 1, fadeOutMs: 1, rainDuringIntro: false, postIntroDelayMs: 1, rampUpMs: 1 });
```

(c) The `toTypeConfig` test passes an `IntroScript` literal; add the three fields so it type-checks:

```ts
    const cfg = toTypeConfig({ lines: [], charMs: 80, startDelayMs: 100, fadeOutMs: 200, rainDuringIntro: true, postIntroDelayMs: 0, rampUpMs: 0 });
```

(d) Add a new `describe` block for the new sanitize behavior:

```ts
describe("sanitizeIntro — rain fields", () => {
  it("defaults the rain fields when missing", () => {
    const s = sanitizeIntro({});
    expect(s.rainDuringIntro).toBe(true);
    expect(s.postIntroDelayMs).toBe(0);
    expect(s.rampUpMs).toBe(0);
  });

  it("clamps post-intro delay (0–10000) and ramp-up (0–60000)", () => {
    const hi = sanitizeIntro({ postIntroDelayMs: 99999, rampUpMs: 999999 });
    expect(hi.postIntroDelayMs).toBe(10000);
    expect(hi.rampUpMs).toBe(60000);
    const lo = sanitizeIntro({ postIntroDelayMs: -50, rampUpMs: -1 });
    expect(lo.postIntroDelayMs).toBe(0);
    expect(lo.rampUpMs).toBe(0);
  });

  it("coerces rainDuringIntro to a boolean, defaulting non-booleans to true", () => {
    expect(sanitizeIntro({ rainDuringIntro: false }).rainDuringIntro).toBe(false);
    expect(sanitizeIntro({ rainDuringIntro: "no" }).rainDuringIntro).toBe(true);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx vitest run test/introStore.test.ts`
Expected: FAIL — type errors (the literals/asserts reference fields that don't exist yet) and the new assertions fail.

- [ ] **Step 3: Add the fields to the interface and defaults**

In `src/config/introStore.ts`, change the `IntroScript` interface to:

```ts
/** User-editable intro: the lines, the global timing settings, and the rain-start choreography. */
export interface IntroScript {
  lines: MessageLine[];
  charMs: number;
  startDelayMs: number;
  fadeOutMs: number;
  rainDuringIntro: boolean; // true = rain falls during the intro; false = waits until after
  postIntroDelayMs: number; // after-mode only: gap between intro end and rain start
  rampUpMs: number;         // linear density ramp 0→full once the rain starts (0 = instant)
}
```

Change `DEFAULT_INTRO` to include the new defaults:

```ts
export const DEFAULT_INTRO: IntroScript = {
  lines: DEFAULT_LINES.map((l) => ({ ...l })),
  charMs: DEFAULT_TYPE_CONFIG.charMs,
  startDelayMs: DEFAULT_TYPE_CONFIG.startDelayMs,
  fadeOutMs: DEFAULT_TYPE_CONFIG.fadeOutMs,
  rainDuringIntro: true,
  postIntroDelayMs: 0,
  rampUpMs: 0,
};
```

- [ ] **Step 4: Add the fields to `sanitizeIntro`**

In `src/config/introStore.ts`, change the `return` object inside `sanitizeIntro` to add the three fields:

```ts
  return {
    lines: lines.length > 0 ? lines : DEFAULT_INTRO.lines.map((l) => ({ ...l })),
    charMs: num(r.charMs, 10, 500, DEFAULT_INTRO.charMs),
    startDelayMs: num(r.startDelayMs, 0, 10000, DEFAULT_INTRO.startDelayMs),
    fadeOutMs: num(r.fadeOutMs, 0, 10000, DEFAULT_INTRO.fadeOutMs),
    rainDuringIntro: typeof r.rainDuringIntro === "boolean" ? r.rainDuringIntro : DEFAULT_INTRO.rainDuringIntro,
    postIntroDelayMs: num(r.postIntroDelayMs, 0, 10000, DEFAULT_INTRO.postIntroDelayMs),
    rampUpMs: num(r.rampUpMs, 0, 60000, DEFAULT_INTRO.rampUpMs),
  };
```

- [ ] **Step 5: Run the tests + full suite + typecheck**

Run: `npx tsc --noEmit && npm test`
Expected: no type errors; all tests green (introStore, plus the rest still pass).

- [ ] **Step 6: Commit**

```bash
git add src/config/introStore.ts test/introStore.test.ts
git commit -m "Add rain-choreography fields to IntroScript with sanitize bounds"
```

---

### Task 4: Editor "Rain" section

**Files:**
- Modify: `src/ui/introEditor.ts`
- Modify: `src/styles.css`

**Interfaces:**
- Consumes: `IntroScript.rainDuringIntro/postIntroDelayMs/rampUpMs` (Task 3). Uses the existing `secondsField` helper.
- Produces: a new "Rain" section in the modal; a `toggleField` helper on `IntroEditor`.

This is a DOM UI change with no Node-testable logic (like the rest of `introEditor.ts`): verified by `npx tsc --noEmit` and the existing suite. Do NOT add a vitest test for the modal.

- [ ] **Step 1: Add the `toggleField` helper**

In `src/ui/introEditor.ts`, add this method immediately after `secondsField(...)` (before `iconButton`):

```ts
  private toggleField(label: string, value: boolean, onChange: (v: boolean) => void): HTMLElement {
    const field = document.createElement("label");
    field.className = "mx-field";
    const span = document.createElement("span");
    span.textContent = label;
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "mx-toggle";
    const render = (v: boolean): void => {
      btn.setAttribute("aria-pressed", String(v));
      btn.textContent = v ? "On" : "Off";
    };
    render(value);
    btn.addEventListener("click", () => {
      const v = btn.getAttribute("aria-pressed") !== "true";
      render(v);
      onChange(v);
    });
    field.append(span, btn);
    return field;
  }
```

- [ ] **Step 2: Add the "Rain" section to `build()`**

In `src/ui/introEditor.ts`, inside `build()`, find the end of the Timing section:

```ts
    timing.appendChild(this.secondsField("Fade out (s)", this.draft.fadeOutMs, (ms) => (this.draft.fadeOutMs = ms)));
    this.dialog.appendChild(timing);
```

Insert this block immediately after `this.dialog.appendChild(timing);` (before the footer is built):

```ts
    this.dialog.appendChild(this.heading("h3", "Rain"));
    const rain = document.createElement("div");
    rain.className = "mx-line-timings";
    const delay = this.secondsField("Delay after intro (s)", this.draft.postIntroDelayMs, (ms) => (this.draft.postIntroDelayMs = ms));
    const delayInput = delay.querySelector("input");
    const applyDelayEnabled = (): void => {
      if (delayInput) delayInput.disabled = this.draft.rainDuringIntro; // delay only applies in after-mode
    };
    rain.appendChild(this.toggleField("Rain during intro", this.draft.rainDuringIntro, (v) => {
      this.draft.rainDuringIntro = v;
      applyDelayEnabled();
    }));
    rain.appendChild(delay);
    rain.appendChild(this.secondsField("Ramp-up (s)", this.draft.rampUpMs, (ms) => (this.draft.rampUpMs = ms)));
    applyDelayEnabled();
    this.dialog.appendChild(rain);
```

- [ ] **Step 3: Add modal-toggle styling**

The existing `.mx-toggle` CSS is scoped to `.mx-row .mx-toggle` (the controls panel). Append a modal-scoped rule to the end of `src/styles.css`:

```css
.mx-modal .mx-toggle {
  font-family: var(--mx-font);
  font-size: 12px;
  color: var(--mx-green);
  background: rgb(var(--mx-accent-rgb) / 0.06);
  border: 1px solid var(--mx-border);
  border-radius: 5px;
  padding: 5px 10px;
  cursor: pointer;
}
.mx-modal .mx-toggle[aria-pressed="true"] {
  background: rgb(var(--mx-accent-rgb) / 0.22);
  border-color: var(--mx-green);
}
```

- [ ] **Step 4: Typecheck + suite**

Run: `npx tsc --noEmit && npm test`
Expected: no type errors; suite still green (no new tests).

- [ ] **Step 5: Commit**

```bash
git add src/ui/introEditor.ts src/styles.css
git commit -m "Add Rain section to intro editor (during/after, delay, ramp-up)"
```

---

### Task 5: Wire the choreography into the app

**Files:**
- Modify: `src/app.ts`

**Interfaces:**
- Consumes: `densityRampFactor` (Task 2), `RainSim.reset()` (Task 1), `IntroScript` rain fields (Task 3), existing `IntroStore`/`sanitizeIntro`/`toTypeConfig`/`resolveLines`.
- Produces: a `startIntroSequence(script)` used by first-visit autoplay, Replay, and Preview; loop density-ramp gating.

This is integration/DOM glue (no Node unit test). Verified by `npx tsc --noEmit`, `npm test` (the full suite still passes), `npm run build`, and a controller-run Playwright smoke. The P-key pause (`userPaused`) and super-fullscreen paths must remain untouched.

- [ ] **Step 1: Import the ramp helper**

In `src/app.ts`, add after the existing `./sim/...` imports (e.g. right after the line importing from `./sim/messageOverlay.ts`):

```ts
import { densityRampFactor } from "./sim/introRain.ts";
```

- [ ] **Step 2: Add choreography state**

In `src/app.ts`, find:

```ts
  let last = 0;
  let userPaused = false;
```

Replace with:

```ts
  let last = 0;
  let userPaused = false;
  // Intro rain choreography. Default sentinel: rain already running at full (no intro / repeat visit).
  let rainStartAtMs = Number.NEGATIVE_INFINITY;
  let rampUpMs = 0;
  let rainPendingAfterIntro = false;
  let pendingPostIntroDelayMs = 0;
```

- [ ] **Step 3: Add `startIntroSequence` and route preview through it**

In `src/app.ts`, find the `seedOverlay` + preview/save block:

```ts
  // Reflect the stored script onto the live overlay (resolving {name}).
  const seedOverlay = (): void => {
    if (!message || !introStore) return;
    const s = introStore.get();
    message.setScript(resolveLines(s.lines, viewerName), toTypeConfig(s));
  };
  seedOverlay();

  // Preview/save run through the overlay; markSeenPending gates the first-visit flag.
  let introPreviewActive = false;
  let markSeenPending = false;

  const previewIntro = (draft: IntroScript): void => {
    if (!message) return;
    const clean = sanitizeIntro(draft);
    introPreviewActive = true;
    message.setScript(resolveLines(clean.lines, viewerName), toTypeConfig(clean));
    message.play(performance.now());
  };
```

Replace it with:

```ts
  // Reflect the stored script onto the live overlay (resolving {name}).
  const seedOverlay = (): void => {
    if (!message || !introStore) return;
    const s = introStore.get();
    message.setScript(resolveLines(s.lines, viewerName), toTypeConfig(s));
  };
  seedOverlay();

  // Play the intro and choreograph the rain (during/after + post-intro delay + density ramp).
  // Used by first-visit autoplay, Replay, and Preview.
  const startIntroSequence = (script: IntroScript): void => {
    if (!message) return;
    message.setScript(resolveLines(script.lines, viewerName), toTypeConfig(script));
    // Under reduced motion the loop isn't running; skip choreography so an after-mode
    // trigger can't leave a stuck black frame. Behaves like today (a visual no-op).
    if (!reduceMq.matches) {
      rampUpMs = script.rampUpMs;
      rainPendingAfterIntro = false;
      if (!script.rainDuringIntro) {
        sim.reset(); // black until the intro ends
        rainStartAtMs = Number.POSITIVE_INFINITY;
        rainPendingAfterIntro = true;
        pendingPostIntroDelayMs = script.postIntroDelayMs;
      } else if (script.rampUpMs > 0) {
        sim.reset(); // build from empty starting now
        rainStartAtMs = performance.now();
      } else {
        rainStartAtMs = Number.NEGATIVE_INFINITY; // during + no ramp = today's behaviour
        rampUpMs = 0;
      }
    }
    message.play(performance.now());
  };

  // Preview/save run through the overlay; markSeenPending gates the first-visit flag.
  let introPreviewActive = false;
  let markSeenPending = false;

  const previewIntro = (draft: IntroScript): void => {
    introPreviewActive = true;
    startIntroSequence(sanitizeIntro(draft));
  };
```

(`startIntroSequence` references `reduceMq` and `sim`, both declared later/elsewhere in `mountMatrixRain`; this is safe because the closure only runs at runtime, after they're initialized — the same forward-reference pattern already used for `editor` in the `onDone` handler.)

- [ ] **Step 4: Set the rain-start moment when the intro ends**

In `src/app.ts`, find the `onDone` handler:

```ts
  // A single onDone handler serves both the first-visit flag and preview restore.
  message?.onDone(() => {
    if (introPreviewActive) {
      introPreviewActive = false;
      editor?.endPreview();
    }
```

Replace those lines with:

```ts
  // A single onDone handler serves the after-mode rain start, preview restore, and first-visit flag.
  message?.onDone(() => {
    if (rainPendingAfterIntro) {
      rainPendingAfterIntro = false;
      rainStartAtMs = performance.now() + pendingPostIntroDelayMs;
    }
    if (introPreviewActive) {
      introPreviewActive = false;
      editor?.endPreview();
    }
```

- [ ] **Step 5: Route Replay through the sequence**

In `src/app.ts`, find the panel construction callback:

```ts
        onReplayIntro: () => message?.play(performance.now()),
```

Replace with:

```ts
        onReplayIntro: () => { if (introStore) startIntroSequence(introStore.get()); },
```

- [ ] **Step 6: Gate the loop on rain-start and ramp the density**

In `src/app.ts`, find the non-super loop body:

```ts
    flushResize();
    const dt = Math.min((now - last) / 1000, 1 / 15);
    last = now;
    sim.update(dt, controls.get());
    stateTex.upload(sim.state);
    renderer.renderFrame(paramsOf(controls.get()), grid);
    message?.update(now);
```

Replace with:

```ts
    flushResize();
    const dt = Math.min((now - last) / 1000, 1 / 15);
    last = now;
    if (now >= rainStartAtMs) {
      const f = densityRampFactor(now, rainStartAtMs, rampUpMs);
      const c = controls.get();
      sim.update(dt, f >= 1 ? c : { ...c, density: c.density * f });
    }
    // Before rainStartAtMs (after-mode, pre-start): don't advance — the empty grid renders black.
    stateTex.upload(sim.state);
    renderer.renderFrame(paramsOf(controls.get()), grid);
    message?.update(now);
```

- [ ] **Step 7: Route first-visit autoplay through the sequence**

In `src/app.ts`, find `maybePlayIntro`:

```ts
  const maybePlayIntro = (): void => {
    if (!message || reduceMq.matches) return;
    let seen = false;
    try {
      seen = localStorage.getItem(INTRO_KEY) === "1";
    } catch {
      /* ignore */
    }
    if (seen) return;
    markSeenPending = true;
    message.play(performance.now());
  };
```

Replace with:

```ts
  const maybePlayIntro = (): void => {
    if (!message || !introStore || reduceMq.matches) return;
    let seen = false;
    try {
      seen = localStorage.getItem(INTRO_KEY) === "1";
    } catch {
      /* ignore */
    }
    if (seen) return;
    markSeenPending = true;
    startIntroSequence(introStore.get());
  };
```

- [ ] **Step 8: Typecheck, full suite, and production build**

Run: `npx tsc --noEmit && npm test && npm run build`
Expected: no type errors; all tests pass; `dist/matrixcode.html` builds successfully.

- [ ] **Step 9: Commit**

```bash
git add src/app.ts
git commit -m "Choreograph rain start with the intro: during/after, delay, density ramp"
```

---

## Self-Review Notes

- **Spec coverage:** during/after toggle (Task 3 field + Task 4 toggle + Task 5 `rainDuringIntro` branch); post-intro delay (field + field UI + `onDone` sets `rainStartAtMs`); density ramp (field + UI + `densityRampFactor` in the loop, Task 2); empty-start vs warm-up (`sim.reset()` only for after-mode or ramp>0, Task 5; warm-up at mount untouched); black during after-mode pre-start (loop skips `sim.update`, renders empty state); applies only when the intro plays (only `startIntroSequence` sets the choreography state; default sentinel keeps the loop at full); reduced-motion guard (Task 5 Step 3); Replay/Preview reproduce it (Steps 3 & 5); persistence + sanitize bounds (Task 3); seconds-in-UI/ms-stored (existing `secondsField`); defaults reproduce today (sentinel + ramp 0 + during).
- **Type consistency:** `startIntroSequence(script: IntroScript)`, `densityRampFactor(now, rainStartAtMs, rampUpMs)`, `RainSim.reset()`, and the `IntroScript` field names (`rainDuringIntro`, `postIntroDelayMs`, `rampUpMs`) are used identically across tasks. Loop variables `rainStartAtMs`/`rampUpMs`/`rainPendingAfterIntro`/`pendingPostIntroDelayMs` are declared once (Step 2) and read in the loop (Step 6) and `onDone` (Step 4).
- **No placeholders:** every code step contains complete, runnable code.
- **Don't-break list:** `userPaused` P-key pause (loop/`start()` untouched except the density gate, which preserves today's behavior via the sentinel), super-fullscreen path (returns before the modified loop body), and the no-intro/reduced-motion paths (sentinel keeps `f = 1`).
