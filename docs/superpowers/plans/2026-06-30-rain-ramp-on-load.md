# Rain Ramp-up on Every Load — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the rain build up to the current density over the configurable intro `rampUpMs` on **every** page load (repeat visits), not just during the intro.

**Architecture:** Reuse the existing `densityRampFactor` → `RainSim.activeColumnLimit` ramp machinery. Add one pure decision helper (`loadRampMs`) and wire it into `app.ts` so a repeat-visit load with `rampUpMs > 0` starts the rain from an empty grid and ramps it — the same thing the intro's during-mode-with-ramp branch already does. A tiny `beginRampFromEmpty` helper removes the duplicated reset/start lines. One clarifying hint added to the intro editor.

**Tech Stack:** TypeScript, Vite, Vitest (Node env, no DOM), WebGL2 (untouched here).

## Global Constraints

- Default `rampUpMs` stays **0** — out of the box nothing changes; the ramp is opt-in via the intro editor.
- Ramp affects density only (via active-column count); `speed`, the linear curve, and all other behaviour are unchanged.
- No ramp under `prefers-reduced-motion` (static full frame) or in super-fullscreen/panel windows.
- Commit messages: concise single line, no `Co-Authored-By`.
- Tests run in a Node environment (no DOM) — `app.ts` / editor changes are verified by `tsc --noEmit`, the full suite, and a manual check.

---

### Task 1: `loadRampMs` pure decision helper

**Files:**
- Modify: `src/sim/introRain.ts` (add `loadRampMs` alongside `densityRampFactor`)
- Test: `test/introRain.test.ts` (add a `loadRampMs` describe block)

**Interfaces:**
- Consumes: nothing.
- Produces: `loadRampMs(introSeen: boolean, rampUpMs: number, reducedMotion: boolean): number` — returns the ramp duration (ms) to apply on a normal page load, or `0` to keep the pre-warmed full-density start.

- [ ] **Step 1: Write the failing test**

Add this import-line change at the top of `test/introRain.test.ts` — replace:

```ts
import { densityRampFactor } from "../src/sim/introRain.ts";
```

with:

```ts
import { densityRampFactor, loadRampMs } from "../src/sim/introRain.ts";
```

Then append this describe block to `test/introRain.test.ts` (after the existing `densityRampFactor` block):

```ts
describe("loadRampMs", () => {
  it("is 0 on a first visit, regardless of the configured ramp", () => {
    expect(loadRampMs(false, 5000, false)).toBe(0);
  });

  it("is 0 under reduced motion", () => {
    expect(loadRampMs(true, 5000, true)).toBe(0);
  });

  it("is 0 when the configured ramp is zero or negative", () => {
    expect(loadRampMs(true, 0, false)).toBe(0);
    expect(loadRampMs(true, -1, false)).toBe(0);
  });

  it("is the configured ramp on a repeat visit with motion allowed", () => {
    expect(loadRampMs(true, 5000, false)).toBe(5000);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/introRain.test.ts`
Expected: FAIL — `loadRampMs is not a function` / no export named `loadRampMs`.

- [ ] **Step 3: Write minimal implementation**

In `src/sim/introRain.ts`, append below `densityRampFactor`:

```ts
/**
 * Ramp duration (ms) to apply when the rain starts on a normal page load, or 0 to keep the
 * pre-warmed full-density start. A first visit (intro not yet seen) returns 0 — the intro path
 * owns its ramp; reduced motion returns 0 — the static frame doesn't animate.
 */
export function loadRampMs(introSeen: boolean, rampUpMs: number, reducedMotion: boolean): number {
  if (!introSeen || reducedMotion || rampUpMs <= 0) return 0;
  return rampUpMs;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/introRain.test.ts`
Expected: PASS (all `densityRampFactor` + `loadRampMs` cases green).

- [ ] **Step 5: Commit**

```bash
git add src/sim/introRain.ts test/introRain.test.ts
git commit -m "Add loadRampMs helper deciding the load-time density ramp"
```

---

### Task 2: Wire the load-time ramp into `app.ts` + clarify the editor field

**Files:**
- Modify: `src/app.ts` (import `loadRampMs`; add `beginRampFromEmpty`; route the intro during-ramp branch through it; ramp on the repeat-visit path)
- Modify: `src/ui/introEditor.ts` (one clarifying hint under the Rain section)

**Interfaces:**
- Consumes: `loadRampMs` (Task 1); existing in-scope state in `mountMatrixRain`: `rampUpMs`, `rainPendingAfterIntro`, `rainStartAtMs`, `sim`, `reduceMq`, `introStore`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Import `loadRampMs`**

In `src/app.ts`, replace:

```ts
import { densityRampFactor } from "./sim/introRain.ts";
```

with:

```ts
import { densityRampFactor, loadRampMs } from "./sim/introRain.ts";
```

- [ ] **Step 2: Add the `beginRampFromEmpty` helper just before `startIntroSequence`**

In `src/app.ts`, find the comment + start of `startIntroSequence`:

```ts
  // Play the intro and choreograph the rain (during/after + post-intro delay + density ramp).
  // Used by first-visit autoplay, Replay, and Preview.
  const startIntroSequence = (script: IntroScript): void => {
```

Insert this helper immediately **above** that comment:

```ts
  // Start the rain from an empty grid and linearly ramp it to the configured density over `ms`,
  // via the loop's densityRampFactor → activeColumnLimit. Shared by the intro's during-mode ramp
  // and the repeat-visit (no-intro) load ramp.
  const beginRampFromEmpty = (ms: number): void => {
    rampUpMs = ms;
    rainPendingAfterIntro = false;
    sim.reset();
    rainStartAtMs = performance.now();
  };

```

- [ ] **Step 3: Route the intro's during-ramp branch through the helper (DRY)**

In `src/app.ts`, inside `startIntroSequence`, replace this block:

```ts
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
```

with:

```ts
    if (!reduceMq.matches) {
      if (!script.rainDuringIntro) {
        rampUpMs = script.rampUpMs;
        rainPendingAfterIntro = false;
        sim.reset(); // black until the intro ends
        rainStartAtMs = Number.POSITIVE_INFINITY;
        rainPendingAfterIntro = true;
        pendingPostIntroDelayMs = script.postIntroDelayMs;
      } else if (script.rampUpMs > 0) {
        beginRampFromEmpty(script.rampUpMs); // build from empty starting now
      } else {
        rainStartAtMs = Number.NEGATIVE_INFINITY; // during + no ramp = today's behaviour
        rampUpMs = 0;
        rainPendingAfterIntro = false;
      }
    }
```

(The after-mode and no-ramp branches now set `rampUpMs`/`rainPendingAfterIntro` explicitly instead of via shared top-of-block defaults, so the during-ramp branch can delegate fully to `beginRampFromEmpty` with no redundant assignment. Behaviour is identical: after-mode → reset + `+Infinity` start + pending; during+ramp → reset + ramp from now; during+no-ramp → `-Infinity` sentinel, no ramp.)

- [ ] **Step 4: Ramp on the repeat-visit path in `maybePlayIntro`**

In `src/app.ts`, find the `maybePlayIntro` seen-check and replace:

```ts
    if (seen) return;
    markSeenPending = true;
    startIntroSequence(introStore.get());
```

with:

```ts
    if (seen) {
      // Repeat visit (no intro): start the rain from empty and ramp to density, reusing the
      // intro's rampUpMs. loadRampMs returns 0 (keep the warmed full start) unless a ramp is set.
      const ms = loadRampMs(true, introStore.get().rampUpMs, reduceMq.matches);
      if (ms > 0) beginRampFromEmpty(ms);
      return;
    }
    markSeenPending = true;
    startIntroSequence(introStore.get());
```

- [ ] **Step 5: Type-check and run the full suite**

Run: `npx tsc --noEmit`
Expected: no errors.

Run: `npm test`
Expected: all suites pass (including the new `loadRampMs` cases).

- [ ] **Step 6: Add the clarifying hint to the intro editor**

In `src/ui/introEditor.ts`, find the end of the Rain section:

```ts
    rain.appendChild(this.secondsField("Ramp-up (s)", this.draft.rampUpMs, (ms) => (this.draft.rampUpMs = ms)));
    applyDelayEnabled();
    this.dialog.appendChild(rain);
```

Replace it with:

```ts
    rain.appendChild(this.secondsField("Ramp-up (s)", this.draft.rampUpMs, (ms) => (this.draft.rampUpMs = ms)));
    applyDelayEnabled();
    this.dialog.appendChild(rain);

    const rampHint = document.createElement("p");
    rampHint.className = "mx-modal-hint";
    rampHint.textContent = "Ramp-up applies whenever the rain starts — during the intro and on every page reload.";
    this.dialog.appendChild(rampHint);
```

- [ ] **Step 7: Type-check again**

Run: `npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 8: Manual verification (dev server on port 5188 assumed running)**

1. Open the app. If it's a first visit, let the intro play (or press Escape) so it's marked seen — confirm `localStorage["mx-intro-seen"] === "1"`.
2. Press `H`, click **✎ Edit intro**, set **Ramp-up (s)** to e.g. `6`, Save.
3. Reload the page. Expected: the screen starts (near-)empty and the rain visibly builds up to full density over ~6s, then holds at the configured density.
4. Set **Ramp-up (s)** back to `0`, Save, reload. Expected: the screen starts already full (today's behaviour).
5. (Optional) Enable OS "Reduce motion" with a non-zero ramp + reload. Expected: a static, full-density frame — no ramp animation.

- [ ] **Step 9: Commit**

```bash
git add src/app.ts src/ui/introEditor.ts
git commit -m "Ramp the rain up to density on every page load, not just the intro"
```

---

## Self-Review

**Spec coverage:**
- Repeat-visit ramp via existing mechanism → Task 2 Step 4. ✓
- First-visit / Replay / Preview unchanged → Task 2 Step 3 preserves `startIntroSequence` behaviour. ✓
- Reduced motion excluded → `loadRampMs` (Task 1) + `maybePlayIntro`'s existing `reduceMq` early-return. ✓
- `rampUpMs` default stays 0 → unchanged in `introStore.ts`; no task touches it. ✓
- Pure unit-testable helper → Task 1. ✓
- Editor hint → Task 2 Step 6. ✓
- Super/panel untouched → no task touches the panel/super paths. ✓

**Placeholder scan:** none — every step has exact old/new code and exact commands.

**Type consistency:** `loadRampMs(boolean, number, boolean): number` and `beginRampFromEmpty(ms: number): void` are used with matching signatures in every reference.
