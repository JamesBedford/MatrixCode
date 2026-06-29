import { type IntroScript, IntroStore, DEFAULT_INTRO, cloneIntro } from "../config/introStore.ts";
import { DEFAULT_HOLD_MS, DEFAULT_PAUSE_MS } from "../sim/messageOverlay.ts";

export interface IntroEditorCallbacks {
  /** Play the draft over the rain (the editor hides itself first). */
  onPreview: (draft: IntroScript) => void;
  /** Persist the draft and update the live overlay. */
  onSave: (draft: IntroScript) => void;
  /** Discard the draft. */
  onCancel: () => void;
}

/** Centered modal for editing the typed-intro script. Mirrors ControlsPanel's vanilla-DOM style. */
export class IntroEditor {
  readonly el: HTMLDivElement; // backdrop
  private dialog: HTMLDivElement;
  private linesEl: HTMLDivElement;
  private draft: IntroScript;
  private isOpen = false;
  private previewing = false;

  constructor(parent: HTMLElement, private store: IntroStore, private cb: IntroEditorCallbacks) {
    this.draft = cloneIntro(DEFAULT_INTRO);

    this.el = document.createElement("div");
    this.el.className = "mx-modal-backdrop";
    this.el.style.display = "none";
    this.el.addEventListener("click", (e) => {
      if (e.target === this.el) this.cancel();
    });

    this.dialog = document.createElement("div");
    this.dialog.className = "mx-modal";
    this.dialog.setAttribute("role", "dialog");
    this.dialog.setAttribute("aria-modal", "true");
    this.dialog.setAttribute("aria-label", "Edit intro");
    this.el.appendChild(this.dialog);

    this.linesEl = document.createElement("div");

    parent.appendChild(this.el);
    // Capture phase so this runs before app.ts's window keydown handler; while the
    // editor is open we swallow shortcuts (incl. f/h) and handle Escape ourselves.
    window.addEventListener("keydown", this.onKeyDownCapture, true);
  }

  private onKeyDownCapture = (e: KeyboardEvent): void => {
    if (!this.isOpen || this.previewing) return;
    e.stopPropagation();
    if (e.key === "Escape") {
      e.preventDefault();
      this.cancel();
    }
  };

  open(): void {
    this.draft = this.store.get();
    this.build();
    this.el.style.display = "grid";
    this.isOpen = true;
    this.previewing = false;
  }

  private hide(): void {
    this.el.style.display = "none";
    this.isOpen = false;
  }

  /** Called by the app when a preview ends (finished or skipped) to restore the editor. */
  endPreview(): void {
    if (!this.previewing) return;
    this.previewing = false;
    this.el.style.display = "grid";
  }

  private cancel(): void {
    this.hide();
    this.cb.onCancel();
  }

  private save(): void {
    this.hide();
    this.cb.onSave(cloneIntro(this.draft));
  }

  private preview(): void {
    this.previewing = true;
    this.el.style.display = "none"; // unobstruct the centered intro; restored via endPreview()
    this.cb.onPreview(cloneIntro(this.draft));
  }

  private build(): void {
    this.dialog.replaceChildren();

    this.dialog.appendChild(this.heading("h2", "Edit intro"));
    this.dialog.appendChild(this.heading("h3", "Lines"));

    const hint = document.createElement("p");
    hint.className = "mx-modal-hint";
    hint.textContent = "Use {name} to insert the visitor's name.";
    this.dialog.appendChild(hint);

    this.linesEl = document.createElement("div");
    this.dialog.appendChild(this.linesEl);
    this.renderLines();

    const add = this.textButton("+ Add line", "mx-btn mx-modal-add", () => {
      this.draft.lines.push({ text: "", holdMs: DEFAULT_HOLD_MS, pauseMs: DEFAULT_PAUSE_MS });
      this.renderLines();
    });
    this.dialog.appendChild(add);

    this.dialog.appendChild(this.heading("h3", "Timing"));
    const timing = document.createElement("div");
    timing.className = "mx-line-timings";
    timing.appendChild(this.numberField("Typing speed (ms/char)", this.draft.charMs, 10, 500, 5, (v) => (this.draft.charMs = v)));
    timing.appendChild(this.secondsField("Start delay (s)", this.draft.startDelayMs, (ms) => (this.draft.startDelayMs = ms)));
    timing.appendChild(this.secondsField("Fade out (s)", this.draft.fadeOutMs, (ms) => (this.draft.fadeOutMs = ms)));
    this.dialog.appendChild(timing);

    const footer = document.createElement("div");
    footer.className = "mx-modal-footer";
    footer.appendChild(this.textButton("Reset to default", "mx-btn mx-reset", () => {
      this.draft = cloneIntro(DEFAULT_INTRO);
      this.build();
    }));
    footer.appendChild(this.textButton("Cancel", "mx-btn", () => this.cancel()));
    footer.appendChild(this.textButton("Preview", "mx-btn", () => this.preview()));
    footer.appendChild(this.textButton("Save", "mx-btn", () => this.save()));
    this.dialog.appendChild(footer);
  }

  private renderLines(): void {
    this.linesEl.replaceChildren();
    const lines = this.draft.lines;
    lines.forEach((line, i) => {
      const row = document.createElement("div");
      row.className = "mx-line";

      const reorder = document.createElement("div");
      reorder.className = "mx-line-reorder";
      const up = this.iconButton("↑", "Move line up", () => this.move(i, -1));
      up.disabled = i === 0;
      const down = this.iconButton("↓", "Move line down", () => this.move(i, 1));
      down.disabled = i === lines.length - 1;
      reorder.append(up, down);
      row.appendChild(reorder);

      const text = document.createElement("input");
      text.type = "text";
      text.value = line.text;
      text.placeholder = "(blank line)";
      text.addEventListener("input", () => (line.text = text.value));
      row.appendChild(text);

      const timings = document.createElement("div");
      timings.className = "mx-line-timings";
      timings.appendChild(this.secondsField("Show for (s)", line.holdMs, (ms) => (line.holdMs = ms)));
      const pause = this.secondsField("Pause after (s)", line.pauseMs, (ms) => (line.pauseMs = ms));
      if (i === lines.length - 1) {
        const input = pause.querySelector("input");
        if (input) input.disabled = true; // last line has no following line to pause before
      }
      timings.appendChild(pause);
      const remove = this.iconButton("✕", "Remove line", () => {
        this.draft.lines.splice(i, 1);
        this.renderLines();
      });
      remove.disabled = lines.length === 1; // always keep at least one line
      timings.appendChild(remove);
      row.appendChild(timings);

      this.linesEl.appendChild(row);
    });
  }

  private move(i: number, dir: number): void {
    const j = i + dir;
    const lines = this.draft.lines;
    if (j < 0 || j >= lines.length) return;
    [lines[i], lines[j]] = [lines[j]!, lines[i]!];
    this.renderLines();
  }

  private heading(tag: "h2" | "h3", text: string): HTMLElement {
    const h = document.createElement(tag);
    h.textContent = text;
    return h;
  }

  private numberField(
    label: string,
    value: number,
    min: number,
    max: number,
    step: number,
    onChange: (v: number) => void,
  ): HTMLElement {
    const field = document.createElement("label");
    field.className = "mx-field";
    const span = document.createElement("span");
    span.textContent = label;
    const input = document.createElement("input");
    input.type = "number";
    input.min = String(min);
    input.max = String(max);
    input.step = String(step);
    input.value = String(value);
    input.addEventListener("input", () => {
      const v = Number(input.value);
      if (Number.isFinite(v)) onChange(v);
    });
    field.append(span, input);
    return field;
  }

  private secondsField(label: string, valueMs: number, onChangeMs: (ms: number) => void): HTMLElement {
    return this.numberField(label, valueMs / 1000, 0, 60, 0.1, (s) => onChangeMs(Math.round(s * 1000)));
  }

  private iconButton(label: string, title: string, onClick: () => void): HTMLButtonElement {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "mx-icon-btn";
    b.title = title;
    b.setAttribute("aria-label", title);
    b.textContent = label;
    b.addEventListener("click", onClick);
    return b;
  }

  private textButton(label: string, className: string, onClick: () => void): HTMLButtonElement {
    const b = document.createElement("button");
    b.type = "button";
    b.className = className;
    b.textContent = label;
    b.addEventListener("click", onClick);
    return b;
  }

  destroy(): void {
    window.removeEventListener("keydown", this.onKeyDownCapture, true);
    this.el.remove();
  }
}
