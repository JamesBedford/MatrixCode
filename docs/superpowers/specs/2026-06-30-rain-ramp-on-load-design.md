# Rain Ramp-up on Every Load — Design

## Goal

Let the Matrix rain build up to the current density over a configurable time **whenever it first starts to fall** — not only during the intro. Today a density ramp-up already exists but fires *only* as part of the intro choreography (first visit, **Replay intro**, **Preview**). On a normal repeat visit the screen opens already full, with no ramp.

This extends the **existing** intro `rampUpMs` setting so it *also* applies on repeat visits, rather than adding a new control. (Decision made during brainstorming: "reuse intro's ramp" over a separate top-level control.)

## Scope

- The ramp applies on a **repeat (intro-already-seen) page load** when `IntroScript.rampUpMs > 0`: the rain starts from an empty grid and linearly ramps to the configured density over `rampUpMs`, reusing the existing `densityRampFactor` → `RainSim.activeColumnLimit` mechanism.
- First-visit / Replay / Preview behaviour is **unchanged** (still driven by `startIntroSequence`).
- `rainDuringIntro` and `postIntroDelayMs` are intro-only and stay untouched — there is no intro on a repeat visit, so the rain simply ramps from empty starting at load.
- **`prefers-reduced-motion`**: no ramp — the static, warmed, full-density frame shows as today.
- **Super-fullscreen / panel** windows have no intro and are untouched.
- The ramp affects **active columns → density only** (the existing mechanism); `speed`, curve (linear), etc. are unchanged.

This is the item explicitly listed as out-of-scope in the prior choreography design ("Applying the choreography on no-intro / reduced-motion loads") — now in scope for the no-intro case only. Reduced-motion remains excluded.

## Approach

The machinery already exists and is unit-tested:

- `densityRampFactor(now, rainStartAtMs, rampUpMs)` — linear 0..1 (`src/sim/introRain.ts`).
- `RainSim.activeColumnLimit` + `RainSim.reset()` — the RAF loop already sets `activeColumnLimit = f >= 1 ? Infinity : ceil(f * cols)` each frame from that factor.

So the only new work is **wiring**: on a repeat visit, set `rainStartAtMs`/`rampUpMs` and `sim.reset()` the same way the intro's during-mode-with-ramp branch already does, so the loop ramps from empty.

Rejected alternatives:

- **A separate top-level "Start ramp" control in the main panel** — duplicates a setting that already exists; the user chose to reuse the intro one.
- **Change the `rampUpMs` default to non-zero** — would silently alter both the intro and every repeat load for existing users; kept at 0 (opt-in) instead.

## Behaviour / semantics

On a normal (non-panel) mount, after the GPU is built (which runs the usual `warmUp`) and `start()` has kicked the RAF loop, `maybePlayIntro()` decides the start:

- **Not seen (first visit)** → `startIntroSequence(...)` as today (unchanged).
- **Seen (repeat visit)**, `rampUpMs > 0`, not reduced-motion → start the rain from empty and ramp:
  - `sim.reset()` discards the warmed grid (black start),
  - `rampUpMs = script.rampUpMs`,
  - `rainStartAtMs = performance.now()`.
  The RAF loop then ramps `activeColumnLimit` from ~0 to all columns over `rampUpMs`, reaching the configured density when the ramp completes — identical to the intro's during-mode ramp.
- **Seen**, `rampUpMs == 0` (or reduced-motion) → no change: keep the warmed, full-density start exactly as today.

Ordering note: `start()` runs before `maybePlayIntro()`, and `sim.reset()` happens synchronously before the first RAF `loop` frame, so the first painted frame is the empty grid — no flash of full rain. (No `renderStatic()` runs between `buildGpu` and the loop on this path.)

## Pure helper — `src/sim/introRain.ts`

A small, DOM-free, unit-testable decision function so the load-time branch isn't bare logic in `app.ts` (mirroring why `densityRampFactor` lives here):

```ts
/**
 * Ramp duration (ms) to apply when the rain starts on a normal page load, or 0 to keep
 * the pre-warmed full-density start. First-visit loads (intro not yet seen) return 0 — the
 * intro path owns their ramp; reduced motion returns 0 — no animation.
 */
export function loadRampMs(introSeen: boolean, rampUpMs: number, reducedMotion: boolean): number {
  if (!introSeen || reducedMotion || rampUpMs <= 0) return 0;
  return rampUpMs;
}
```

## `app.ts` wiring

1. Extract a tiny helper used by both the intro's during-mode-ramp branch and the new repeat-visit path, to avoid duplicating the reset/start lines:

   ```ts
   // Start the rain from an empty grid and linearly ramp it to the configured density over `ms`.
   const beginRampFromEmpty = (ms: number): void => {
     rampUpMs = ms;
     rainPendingAfterIntro = false;
     sim.reset();
     rainStartAtMs = performance.now();
   };
   ```

2. In `maybePlayIntro()`, replace the early `return` on the "seen" path:

   ```ts
   if (seen) {
     const ms = loadRampMs(true, introStore.get().rampUpMs, reduceMq.matches);
     if (ms > 0) beginRampFromEmpty(ms);
     return;
   }
   ```

   (`maybePlayIntro` already returns early when `reduceMq.matches`, so the guard is redundant-but-explicit; `loadRampMs` encodes it for the unit test.)

The RAF loop, the `onReduceChange` reset path, and the context-restore path are unchanged — they already key off `rainStartAtMs`/`rampUpMs`.

## Editor UI — `src/ui/introEditor.ts`

Keep the **"Ramp-up (s)"** field where it is (intro editor → **Rain** section). Add a one-line hint under that section clarifying the ramp-up applies whenever the rain starts — the intro *or* a reload — since the field now does more than the intro. No new control, no relocation.

## Testing

- **`test/introRain.test.ts`** — add `loadRampMs` cases: returns 0 when not seen (regardless of ramp), 0 under reduced motion, 0 when `rampUpMs <= 0`, and `rampUpMs` when seen + non-zero + motion allowed.
- The ramp math (`densityRampFactor`) and `activeColumnLimit` are already covered by the existing suite — unchanged.
- `app.ts` and the editor hint are DOM/integration (Node-env tests have no DOM): verified by `npx tsc --noEmit`, the full suite, and a manual check — set Ramp-up to a few seconds in Edit intro, reload, and confirm the rain builds from empty to full each load (and that reduced-motion / `rampUpMs = 0` still start full).

## Out of scope (YAGNI)

- A separate main-panel control (reusing the intro setting was the chosen approach).
- Changing the default `rampUpMs` from 0.
- Ramping under reduced motion, or in super-fullscreen/panel windows.
- Non-linear ramp curves, or ramping `speed`.
