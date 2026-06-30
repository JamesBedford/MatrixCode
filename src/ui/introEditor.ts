import { type IntroScript, IntroStore, DEFAULT_INTRO, cloneIntro } from "../config/introStore.ts";
import { DEFAULT_HOLD_MS, DEFAULT_PAUSE_MS } from "../sim/messageOverlay.ts";
import { ModalEditor } from "./modalKit.ts";

export interface IntroEditorCallbacks {
  /** Play the draft over the rain (the editor hides itself first). */
  onPreview: (draft: IntroScript) => void;
  /** Persist the draft and update the live overlay. */
  onSave: (draft: IntroScript) => void;
  /** Discard the draft. */
  onCancel: () => void;
}

/** Centered modal for editing the typed-intro script. Built on the shared ModalEditor kit. */
export class IntroEditor extends ModalEditor {
  private linesEl: HTMLDivElement;
  private draft: IntroScript;

  constructor(parent: HTMLElement, private store: IntroStore, private cb: IntroEditorCallbacks) {
    super(parent, "Edit intro");
    this.draft = cloneIntro(DEFAULT_INTRO);
    this.linesEl = document.createElement("div");
  }

  open(): void {
    this.draft = this.store.get();
    this.build();
    this.show();
  }

  /** Called by the app when a preview ends (finished or skipped) to restore the editor. */
  endPreview(): void {
    this.restoreFromPreview();
  }

  protected requestClose(): void {
    this.cancel();
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
    this.beginPreview(); // unobstruct the centered intro; restored via endPreview()
    this.cb.onPreview(cloneIntro(this.draft));
  }

  protected build(): void {
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

    this.dialog.appendChild(this.footer([
      { label: "Reset to default", className: "mx-btn mx-reset", onClick: () => { this.draft = cloneIntro(DEFAULT_INTRO); this.build(); } },
      { label: "Cancel", onClick: () => this.cancel() },
      { label: "Preview", onClick: () => this.preview() },
      { label: "Save", onClick: () => this.save() },
    ]));
  }

  private renderLines(): void {
    this.reorderableList({
      container: this.linesEl,
      items: this.draft.lines,
      minItems: 1, // always keep at least one line
      renderBody: (line, i, remove) => {
        const text = document.createElement("input");
        text.type = "text";
        text.value = line.text;
        text.placeholder = "(blank line)";
        text.addEventListener("input", () => (line.text = text.value));

        const timings = document.createElement("div");
        timings.className = "mx-line-timings";
        timings.appendChild(this.secondsField("Show for (s)", line.holdMs, (ms) => (line.holdMs = ms)));
        const pause = this.secondsField("Pause after (s)", line.pauseMs, (ms) => (line.pauseMs = ms));
        if (i === this.draft.lines.length - 1) {
          const input = pause.querySelector("input");
          if (input) input.disabled = true; // last line has no following line to pause before
        }
        timings.appendChild(pause);
        timings.appendChild(remove);
        return [text, timings];
      },
    });
  }
}
