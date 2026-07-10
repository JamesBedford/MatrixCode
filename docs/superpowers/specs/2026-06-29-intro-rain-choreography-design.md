# Intro Rain Choreography — Design

## Goal

Extend the intro editor with control over how the Matrix rain starts relative to the typed intro:

- **Rain during intro vs. after** — whether the rain falls while the intro types (today's behaviour) or the screen stays black behind the text until the intro finishes.
- **Post-intro delay** — when the rain waits until after the intro, how long to pause between the intro finishing and the rain starting.
- **Density ramp-up** — how long the rain takes to linearly ramp its density from 0 to the configured value once it starts (e.g. 10 = build up to full density over 10 seconds; 0 = instant).

These settings live in the intro editor modal and are persisted with the rest of the intro script.

## Scope

The choreography applies **only when the intro plays**: first visit, the **Replay intro** button, and the editor's **Preview** — all of which reproduce the full sequence (black-or-rain during the intro per the mode, the post-intro delay, and the density ramp). On repeat visits where the intro is skipped (already seen), and under `prefers-reduced-motion` (where the intro doesn't animate), the rain behaves exactly as it does today: warmed-up and full immediately.

The ramp affects **density only** — `speed` stays at its configured value. The ramp is **linear**. Defaults reproduce today's intro exactly.

## Approach

Three new fields on `IntroScript`, a one-line-math pure helper, and a `RainSim.reset()`, orchestrated by `app.ts` (which already owns the RAF loop and intro lifecycle). Rejected alternatives:

- **Bake the choreography into `RainSim`** — couples the deliberately intro-agnostic, deterministic, headless sim to intro concerns.
- **A dedicated `RainSequencer` class** — over-built; `app.ts` already owns the loop, so a few state variables plus one pure helper suffice.

## New settings — `IntroScript` (`src/config/introStore.ts`)

```ts
interface IntroScript {
  lines: MessageLine[];
  charMs: number;
  startDelayMs: number;
  fadeOutMs: number;
  rainDuringIntro: boolean; // NEW — default true (rain falls during the intro)
  postIntroDelayMs: number; // NEW — default 0; gap after intro end before rain starts (after-mode only)
  rampUpMs: number;         // NEW — default 0; linear density ramp 0→full once rain starts
}
```

Sanitize bounds (added to `sanitizeIntro`):

- `rainDuringIntro` — coerced to boolean; default `true` when missing/non-boolean.
- `postIntroDelayMs` — clamp 0–10000; default 0.
- `rampUpMs` — clamp 0–60000; default 0.

`DEFAULT_INTRO` gains `rainDuringIntro: true, postIntroDelayMs: 0, rampUpMs: 0`. `cloneIntro` already shallow-copies top-level scalars, so it needs no change. Existing stored scripts (from before this feature) lack these fields; `sanitizeIntro` fills the defaults, so the stored intro keeps behaving as today. `toTypeConfig` is unaffected — the choreography fields are not part of `TypeConfig`; `app.ts` reads them from the `IntroScript` directly.

The modal shows durations in **seconds** (stored as ms), consistent with the existing timing fields.

## Choreography semantics

**Rain-start moment** (`rainStartAtMs`, a `performance.now()` timestamp):

- `rainDuringIntro = true` → the sequence-start time (page load / replay / preview).
- `rainDuringIntro = false` → the intro's `onDone` time + `postIntroDelayMs`.

**Before the rain-start moment** (only possible in after-mode): the sim is not advanced, and its empty state renders as black. The typed text (a DOM overlay) shows over the black canvas. (Rendering the empty sim state *is* the black screen — no special clear path is needed, because an all-zero state lights no glyphs.)

**At/after the rain-start moment**: the density passed to `sim.update` each frame is multiplied by `densityRampFactor(now, rainStartAtMs, rampUpMs)`.

**Warm-up vs. empty start**: the existing mount-time 2.5s warm-up (which fills the screen) is kept for the default case (`during` + `rampUpMs == 0`) and for repeat/no-intro visits and reduced-motion. Any choreographed start — `after` mode, or `rampUpMs > 0` in either mode — calls `sim.reset()` so the rain visibly builds from an empty grid. (The warm-up still runs at mount; the reset, when needed, discards it. This only happens when the intro plays, so the cost is negligible.)

## Pure helper — `src/sim/introRain.ts` (new)

```ts
/** Density multiplier (0..1) for the rain at `nowMs`, given when it starts and its ramp duration. */
export function densityRampFactor(nowMs: number, rainStartAtMs: number, rampUpMs: number): number {
  if (nowMs < rainStartAtMs) return 0; // rain hasn't started yet (after-mode pre-start)
  if (rampUpMs <= 0) return 1;          // instant
  return clamp((nowMs - rainStartAtMs) / rampUpMs, 0, 1);
}
```

DOM-free and seedless — fully unit-testable. `clamp` comes from `src/util/math.ts`.

## Sim change — `RainSim.reset()` (`src/sim/rainSim.ts`)

Adds a method that returns the sim to its empty initial condition without reallocating: zero `bright`/`glyphNew`/`glyphOld`/`phase`, deactivate all columns and reseed staggered respawn timers (as the constructor's `seedColumns` does), reset `time` to 0, and zero the packed `state`. This is the same end-state the constructor produces before any `update`. Unit-tested: after `reset()` every `state` byte is 0 and all columns are idle; a subsequent `update` lights cells again (so reset doesn't break the sim).

## `app.ts` wiring

A single `startIntroSequence(script: IntroScript)` is the entry point for first-visit autoplay, **Replay intro**, and **Preview** (replacing the current direct `message.play(...)` calls for those paths).

**Reduced-motion guard:** if `reduceMq.matches`, `startIntroSequence` skips the choreography entirely — no `sim.reset()`, no black phase, `rainStartAtMs` stays the past sentinel — and just calls `message.play(...)` (a visual no-op today, since the loop isn't running). This prevents an after-mode trigger from leaving a static black frame that never recovers.

Otherwise it:

1. Sets the overlay script: `message.setScript(resolveLines(script.lines, viewerName), toTypeConfig(script))` (Preview/Save already sanitize the draft, unchanged).
2. Decides the rain start:
   - `during` + `rampUpMs == 0` → leave the running/warmed-up rain as-is; `rainStartAtMs` is a past sentinel and `rampUpMs` 0 (factor = 1). Identical to today.
   - `during` + `rampUpMs > 0` → `sim.reset()`; `rainStartAtMs = performance.now()`; ramp from now.
   - `after` (any ramp) → `sim.reset()`; mark `rainPendingAfterIntro = true` with the delay; `rainStartAtMs = Infinity` (rain hidden) until the intro ends.
3. `message.play(performance.now())`.

New loop-visible state in `mountMatrixRain`: `rainStartAtMs` (init to a past sentinel so the default/no-intro path always renders), `rampUpMs` (init 0), and `rainPendingAfterIntro` (+ its pending delay).

**The single `message.onDone` handler** gains one more branch: if `rainPendingAfterIntro`, set `rainStartAtMs = performance.now() + pendingDelayMs` and clear the flag. (It already handles preview-restore and the seen-flag.)

**The RAF loop** (non-super path) changes from unconditionally updating to:

```ts
const f = densityRampFactor(now, rainStartAtMs, rampUpMs);
if (f > 0 || now >= rainStartAtMs) {
  const c = controls.get();
  sim.update(dt, f >= 1 ? c : { ...c, density: c.density * f });
}
// else: after-mode pre-start — don't advance; the empty state renders black
stateTex.upload(sim.state);
renderer.renderFrame(paramsOf(controls.get()), grid);
message?.update(now);
```

Reduced-motion / no-intro paths never enter a choreography (the sentinel keeps `f = 1`), so they render the warmed-up rain exactly as today. The multi-monitor fullscreen path is untouched (it has no intro).

## Editor UI — `src/ui/introEditor.ts`

A new **"Rain"** section below "Timing":

- **Rain during intro** — an On/Off toggle reusing the `.mx-toggle` style (a small `toggleField` helper added to the editor). On = `rainDuringIntro: true`.
- **Delay after intro (s)** — a seconds number field bound to `postIntroDelayMs`; disabled when the toggle is On (re-enabled on toggle change without a full rebuild).
- **Ramp-up (s)** — a seconds number field bound to `rampUpMs`.

Editing mutates the working-copy draft (as the existing fields do); Reset/Cancel/Save behave as today and now carry the three new fields.

## Testing

- New `test/introRain.test.ts`: `densityRampFactor` — returns 0 before start, 1 when `rampUpMs<=0`, linear at the midpoint, clamps to [0,1] past the end, and 0 exactly at a future start with a non-zero ramp.
- Extend `test/rainSim.test.ts`: after `reset()` all `state` bytes are 0 and columns are idle; an `update` after reset lights cells again.
- Editor and `app.ts` are DOM/integration (Node-env tests have no DOM): verified by `npx tsc --noEmit`, the existing suite, and the Playwright smoke test extended to toggle the rain settings and confirm persistence.

## Out of scope (YAGNI)

- Ramping `speed` (only density ramps, per the requirement).
- Non-linear ramp curves (easing).
- Applying the choreography on no-intro / reduced-motion loads.
- A fade/opacity transition of the canvas itself (the black-then-build is achieved via the empty grid + ramp, not a CSS fade).
