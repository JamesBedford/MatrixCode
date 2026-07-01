import type { Controls, PresetName, QualityTier } from "../types.ts";
import { DEFAULT_CONTROLS, type ControlsStore } from "../config/controls.ts";

export interface PanelCallbacks {
  onToggleFullscreen: () => void;
  onReplayIntro: () => void;
  onEditIntro: () => void;
  onEditMessages: () => void;
  onEditCountdown: () => void;
}

const HIDE_DELAY_MS = 2800;

/** Auto-hiding control panel + fullscreen button, styled as a Matrix terminal. */
export class ControlsPanel {
  readonly el: HTMLDivElement;
  private panel: HTMLDivElement;
  private hideTimer = 0;
  private pinned = false;
  private destroyed = false;
  // Updates a slider's thumb + readout when its control changes from elsewhere (e.g. keyboard shortcuts).
  private rangeSyncers = new Map<keyof Controls, (c: Controls) => void>();
  private unsubscribe?: () => void;

  constructor(parent: HTMLElement, private controls: ControlsStore, private cb: PanelCallbacks) {
    const c = controls.get();

    this.el = document.createElement("div");
    this.el.className = "mx-ui";

    // Top-right floating buttons.
    const fab = document.createElement("div");
    fab.className = "mx-fab";
    const fsBtn = this.button("⛶ Fullscreen", () => this.cb.onToggleFullscreen());
    fsBtn.title = "Fullscreen (F)";
    fab.appendChild(fsBtn);
    this.el.appendChild(fab);

    // Bottom-left panel.
    this.panel = document.createElement("div");
    this.panel.className = "mx-panel";
    const title = document.createElement("h1");
    title.textContent = "Matrix";
    this.panel.appendChild(title);

    this.range("Density", "density", 0.2, 100, 0.05, (v) => controls.set({ density: v }), (v) => v.toFixed(2), undefined, "Density — adjust with − and =");
    this.range("Ramp-up", "rampUpMs", 0, 30000, 500, (v) => controls.set({ rampUpMs: v }), (v) => (v === 0 ? "off" : `${(v / 1000).toFixed(1)}s`), undefined, "How long the rain builds up to full density when it first starts, on load (0 = instant)");
    // Slider is inverted: right = longer trail. Map slider [0.01,0.5] → stored decay [0.5,0.01].
    this.range("Trail length", "trailLength", 0.01, 0.5, 0.01,
      (v) => controls.set({ trailLength: 0.51 - v }),
      (v) => `${Math.round((v - 0.01) / 0.49 * 100)}%`,
      (c) => 0.51 - c.trailLength);
    this.range("Speed", "speed", 0.2, 3, 0.05, (v) => controls.set({ speed: v }), (v) => `${v.toFixed(2)}×`);
    this.range("Glyph change", "glyphRate", 0, 5, 0.05, (v) => controls.set({ glyphRate: v }), (v) => `${v.toFixed(2)}×`);
    this.range("Glyph size", "glyphScale", 0.5, 10, 0.1, (v) => controls.set({ glyphScale: v }), (v) => `${v.toFixed(1)}×`);
    this.range("Glow", "glow", 0, 2.5, 0.05, (v) => controls.set({ glow: v }), (v) => v.toFixed(2));
    this.range("Lead glow", "leadBrightness", 0, 3, 0.05, (v) => controls.set({ leadBrightness: v }), (v) => v.toFixed(2));

    this.select<PresetName>("Color", c.preset, [
      ["classic", "Classic green"],
      ["amber", "Amber"],
      ["gold", "Gold"],
      ["red", "Red"],
      ["pink", "Pink"],
      ["purple", "Purple"],
      ["blue", "Blue"],
      ["white", "White"],
    ], (v) => controls.set({ preset: v }));

    this.select<QualityTier>("Quality", c.quality, [
      ["low", "Low"],
      ["med", "Medium"],
      ["high", "High"],
    ], (v) => controls.set({ quality: v }));

    this.toggle("Mirror glyphs", c.mirror, (v) => controls.set({ mirror: v }));
    this.toggle("Scanlines", c.scanlines, (v) => controls.set({ scanlines: v }));
    this.toggle("Vignette", c.vignette, (v) => controls.set({ vignette: v }));

    const replay = this.button("▷ Replay intro", () => {
      this.cb.onReplayIntro();
      this.forceHide(); // dismiss the panel so the replayed intro plays unobstructed
    });
    replay.style.marginTop = "6px";
    this.panel.appendChild(replay);

    const edit = this.button("✎ Edit intro", () => this.cb.onEditIntro());
    edit.title = "Edit intro (I)";
    edit.style.marginTop = "6px";
    this.panel.appendChild(edit);

    const editMsgs = this.button("✎ Edit messages", () => this.cb.onEditMessages());
    editMsgs.title = "Edit messages (M)";
    editMsgs.style.marginTop = "6px";
    this.panel.appendChild(editMsgs);

    const editCountdown = this.button("⏱ Edit countdown", () => this.cb.onEditCountdown());
    editCountdown.title = "Edit countdown (C)";
    editCountdown.style.marginTop = "6px";
    this.panel.appendChild(editCountdown);

    // Resets the tunable controls only — the user's custom intro (mx-intro) and
    // messages (mx-messages) live in separate stores and are intentionally left
    // untouched; each has its own "Reset to default" button inside its edit modal.
    const reset = this.button("↺ Reset to defaults", () => {
      controls.set(DEFAULT_CONTROLS);
      location.reload();
    });
    reset.style.marginTop = "6px";
    this.panel.appendChild(reset);

    const hint = document.createElement("p");
    hint.className = "mx-hint";
    hint.innerHTML = "<kbd>F</kbd> fullscreen · <kbd>H</kbd> panel · <kbd>I</kbd> intro · <kbd>M</kbd> messages · <kbd>N</kbd> toggle msgs · <kbd>C</kbd> countdown · <kbd>−</kbd>/<kbd>=</kbd> density";
    this.panel.appendChild(hint);

    this.el.appendChild(this.panel);
    parent.appendChild(this.el);

    this.panel.addEventListener("pointerenter", () => (this.pinned = true));
    this.panel.addEventListener("pointerleave", () => {
      this.pinned = false;
      this.scheduleHide();
    });

    this.onActivity = this.onActivity.bind(this);
    window.addEventListener("pointermove", this.onActivity, { passive: true });
    window.addEventListener("pointerdown", this.onActivity, { passive: true });
    this.unsubscribe = controls.subscribe((state, changed) => {
      for (const key of changed) this.rangeSyncers.get(key)?.(state);
    });
    this.show();
  }

  private button(label: string, onClick: () => void): HTMLButtonElement {
    const b = document.createElement("button");
    b.className = "mx-btn";
    b.type = "button";
    b.textContent = label;
    b.addEventListener("click", onClick);
    return b;
  }

  private row(label: string): HTMLDivElement {
    const row = document.createElement("div");
    row.className = "mx-row";
    const l = document.createElement("label");
    l.textContent = label;
    row.appendChild(l);
    this.panel.appendChild(row);
    return row;
  }

  private range(
    label: string,
    key: keyof Controls,
    min: number,
    max: number,
    step: number,
    onInput: (v: number) => void,
    fmt: (v: number) => string,
    read: (c: Controls) => number = (c) => c[key] as number,
    tooltip?: string,
  ): void {
    const row = this.row(label);
    if (tooltip) row.title = tooltip;
    const val = document.createElement("span");
    val.className = "mx-val";
    row.appendChild(val);
    const input = document.createElement("input");
    input.type = "range";
    input.min = String(min);
    input.max = String(max);
    input.step = String(step);
    const apply = (v: number): void => {
      input.value = String(v);
      val.textContent = fmt(v);
    };
    apply(read(this.controls.get()));
    input.addEventListener("input", () => {
      const v = Number(input.value);
      val.textContent = fmt(v);
      onInput(v);
    });
    row.appendChild(input);
    // Reflect external changes (keyboard shortcuts, reset) back onto the slider.
    this.rangeSyncers.set(key, (c) => apply(read(c)));
  }

  private select<T extends string>(
    label: string,
    value: T,
    options: [T, string][],
    onChange: (v: T) => void,
  ): void {
    const row = this.row(label);
    row.classList.add("mx-row--inline");
    const sel = document.createElement("select");
    for (const [v, text] of options) {
      const opt = document.createElement("option");
      opt.value = v;
      opt.textContent = text;
      if (v === value) opt.selected = true;
      sel.appendChild(opt);
    }
    sel.addEventListener("change", () => onChange(sel.value as T));
    row.appendChild(sel);
  }

  private toggle(label: string, value: boolean, onChange: (v: boolean) => void): void {
    const row = this.row(label);
    row.classList.add("mx-row--inline");
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
    row.appendChild(btn);
  }

  private onActivity(): void {
    this.show();
  }

  show(): void {
    if (this.destroyed) return;
    this.el.classList.add("is-visible");
    document.body.style.cursor = "";
    this.scheduleHide();
  }

  toggleVisible(): void {
    if (this.el.classList.contains("is-visible")) this.forceHide();
    else this.show();
  }

  private scheduleHide(): void {
    window.clearTimeout(this.hideTimer);
    this.hideTimer = window.setTimeout(() => {
      if (!this.pinned) this.forceHide();
    }, HIDE_DELAY_MS);
  }

  private forceHide(): void {
    this.el.classList.remove("is-visible");
    document.body.style.cursor = "none";
  }

  destroy(): void {
    this.destroyed = true;
    this.unsubscribe?.();
    window.clearTimeout(this.hideTimer);
    window.removeEventListener("pointermove", this.onActivity);
    window.removeEventListener("pointerdown", this.onActivity);
    document.body.style.cursor = "";
    this.el.remove();
  }
}
