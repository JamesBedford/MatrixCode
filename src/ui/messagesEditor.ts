import type { MessageDirection, MessageLayout, MessagesDoc } from "../types.ts";
import { MessagesStore, DEFAULT_MESSAGES, cloneMessages } from "../config/messagesStore.ts";
import { ModalEditor } from "./modalKit.ts";
import { momentHint } from "../sim/tokens.ts";

export interface MessagesEditorCallbacks {
  /** Fire one message immediately over the rain (the editor hides itself first). */
  onPreview: (draft: MessagesDoc) => void;
  /** Persist the draft and reconfigure the live scheduler. */
  onSave: (draft: MessagesDoc) => void;
  /** Discard the draft. */
  onCancel: () => void;
}

// Longest the modal stays hidden during a preview before it pops back (a preview is just a peek).
const PREVIEW_MAX_HIDE_MS = 8000;

/** Centered modal for editing the in-rain messages and their scheduling. Built on the ModalEditor kit. */
export class MessagesEditor extends ModalEditor {
  private listEl: HTMLDivElement;
  private draft: MessagesDoc;
  private previewTimer: number | null = null;

  constructor(
    parent: HTMLElement,
    private store: MessagesStore,
    private cb: MessagesEditorCallbacks,
    private getMomentNames: () => string[],
  ) {
    super(parent, "In-rain Messages");
    this.draft = cloneMessages(DEFAULT_MESSAGES);
    this.listEl = document.createElement("div");
  }

  open(): void {
    this.draft = this.store.get();
    this.build();
    this.show();
  }

  protected requestClose(): void {
    this.cancel();
  }

  /** Reflect an externally-toggled "Enable messages" (the keyboard shortcut) into an open editor, keeping other edits. */
  syncEnabled(enabled: boolean): void {
    if (!this.isOpen || this.draft.enabled === enabled) return;
    this.draft.enabled = enabled;
    this.build();
  }

  private cancel(): void {
    this.clearPreviewTimer();
    this.hide();
    this.cb.onCancel();
  }

  private save(): void {
    this.clearPreviewTimer();
    this.hide();
    this.cb.onSave(cloneMessages(this.draft));
  }

  private preview(): void {
    this.beginPreview(); // hide the modal so the rain message is unobstructed
    this.cb.onPreview(cloneMessages(this.draft));
    this.clearPreviewTimer();
    // Stay hidden for the whole animation (fade in + hold + fade out), capped so it's only a peek.
    const total = this.draft.appearMs + this.draft.persistenceMs + this.draft.disappearMs;
    const hideMs = Math.min(total + 500, PREVIEW_MAX_HIDE_MS);
    this.previewTimer = window.setTimeout(() => {
      this.previewTimer = null;
      this.restoreFromPreview();
    }, hideMs);
  }

  private clearPreviewTimer(): void {
    if (this.previewTimer !== null) {
      clearTimeout(this.previewTimer);
      this.previewTimer = null;
    }
  }

  protected build(): void {
    this.dialog.replaceChildren();

    this.dialog.appendChild(this.heading("h2", "In-rain Messages"));
    const settings = document.createElement("fieldset");
    settings.className = "mx-message-settings";
    settings.disabled = !this.draft.enabled;
    const showMessages = this.toggleField("Enable messages", this.draft.enabled, (v) => {
      this.draft.enabled = v;
      settings.disabled = !v;
      preview.disabled = !v;
      reset.disabled = !v;
    });
    showMessages.title = "Enable messages (N)";
    this.dialog.appendChild(showMessages);
    this.dialog.appendChild(settings);
    const layout = document.createElement("div");
    layout.className = "mx-settings-fields";
    layout.appendChild(this.choiceField<MessageLayout>(
      "Message layout",
      this.draft.messageLayout,
      [
        { value: "row", label: "Row across rain" },
        { value: "drop", label: "Single drop" },
      ],
      (v) => {
        this.draft.messageLayout = v;
        this.build();
      },
    ));
    layout.appendChild(this.choiceField<MessageDirection>(
      "Drop direction",
      this.draft.messageDirection,
      [
        { value: "topToBottom", label: "Top to bottom" },
        { value: "bottomToTop", label: "Bottom to top" },
      ],
      (v) => (this.draft.messageDirection = v),
      this.draft.messageLayout !== "drop",
    ));
    settings.appendChild(layout);
    settings.appendChild(this.heading("h3", "Messages"));

    const hint = document.createElement("p");
    hint.className = "mx-modal-hint mx-modal-tooltip-trigger";
    hint.tabIndex = 0;
    hint.setAttribute("aria-describedby", "mx-messages-token-tooltip");
    hint.append(
      "Messages appear inside the rain as a row or inside one falling drop. Raise Density to make them easier to read. Use {name}, {greeting}, {uptime}, {fps}, {time}, {countdown} or {countup}. ⓘ",
    );

    const tooltip = document.createElement("span");
    tooltip.id = "mx-messages-token-tooltip";
    tooltip.className = "mx-modal-tooltip";
    tooltip.setAttribute("role", "tooltip");
    tooltip.textContent = momentHint(this.getMomentNames());
    hint.appendChild(tooltip);
    settings.appendChild(hint);

    this.listEl = document.createElement("div");
    this.listEl.className = "mx-message-list";
    settings.appendChild(this.listEl);
    this.renderMessages();

    const add = this.textButton("Add Message", "mx-btn mx-modal-add", () => {
      this.draft.messages.push("");
      this.renderMessages();
    });
    settings.appendChild(add);

    settings.appendChild(this.heading("h3", "Behaviour"));
    const behaviour = document.createElement("div");
    behaviour.className = "mx-settings-fields";
    behaviour.appendChild(this.secondsField("Show one every (s)", this.draft.frequencyMs, (ms) => (this.draft.frequencyMs = ms)));
    behaviour.appendChild(this.secondsField("Appear over (s)", this.draft.appearMs, (ms) => (this.draft.appearMs = ms)));
    behaviour.appendChild(this.secondsField("Each stays for (s)", this.draft.persistenceMs, (ms) => (this.draft.persistenceMs = ms)));
    behaviour.appendChild(this.secondsField("Disappear over (s)", this.draft.disappearMs, (ms) => (this.draft.disappearMs = ms)));
    behaviour.appendChild(this.percentField(
      "Vertical position (0 top–100 bottom)",
      this.draft.verticalPosition,
      (f) => (this.draft.verticalPosition = f),
    ));
    behaviour.appendChild(this.percentField(
      "Vertical randomness (%)",
      this.draft.verticalJitter,
      (f) => { this.draft.verticalJitter = f; refreshMonitorToggle(); },
    ));
    behaviour.appendChild(this.percentField(
      "Horizontal position (0 left–100 right)",
      this.draft.horizontalPosition,
      (f) => (this.draft.horizontalPosition = f),
    ));
    behaviour.appendChild(this.percentField(
      "Horizontal randomness (%)",
      this.draft.horizontalJitter,
      (f) => { this.draft.horizontalJitter = f; refreshMonitorToggle(); },
    ));
    settings.appendChild(behaviour);

    settings.appendChild(this.heading("h3", "Multi-monitor placement"));
    const monitorMode = this.toggleField("Single message across monitors", this.draft.singleMonitor, (value) => {
      this.draft.singleMonitor = value;
      refreshMonitorToggle();
    });
    const independent = this.toggleField("Independent random positions per monitor", this.draft.independentMonitorPositions,
      (value) => { this.draft.independentMonitorPositions = value; });
    const placementHint = document.createElement("p");
    placementHint.className = "mx-modal-hint";
    const refreshMonitorToggle = (): void => {
      independent.querySelector("button")!.disabled = this.draft.singleMonitor ||
        (this.draft.verticalJitter === 0 && this.draft.horizontalJitter === 0);
      placementHint.textContent = this.draft.singleMonitor
        ? "One message is positioned across the entire monitor space. Position and randomness use the full desktop."
        : "Each monitor shows a copy. Separate positions apply when vertical or horizontal randomness is above zero.";
    };
    refreshMonitorToggle();
    settings.append(monitorMode, independent, placementHint);


    const appendToggleRow = (label: string, value: boolean, onChange: (v: boolean) => void): void => {
      const row = document.createElement("div");
      row.className = "mx-line-timings";
      row.appendChild(this.toggleField(label, value, onChange));
      settings.appendChild(row);
    };
    appendToggleRow("Flicker dissolve", this.draft.flickerOut, (v) => (this.draft.flickerOut = v));
    appendToggleRow("Brightness fade", this.draft.brightnessFade, (v) => (this.draft.brightnessFade = v));

    const reset = this.textButton("Reset to default", "mx-btn mx-reset", () => {
      this.draft = cloneMessages(DEFAULT_MESSAGES);
      this.build();
    });
    reset.disabled = !this.draft.enabled;
    const preview = this.textButton("Preview Message", "mx-btn", () => this.preview());
    preview.disabled = !this.draft.enabled;
    settings.appendChild(preview);
    const footer = this.footer([]);
    footer.append(
      reset,
      this.textButton("Cancel", "mx-btn", () => this.cancel()),
      this.textButton("Save", "mx-btn", () => this.save()),
    );
    this.dialog.appendChild(footer);
  }

  private renderMessages(): void {
    this.reorderableList<string>({
      container: this.listEl,
      items: this.draft.messages,
      minItems: 0, // the list may be emptied to silence messages
      renderBody: (msg, i, remove) => {
        const text = document.createElement("input");
        text.type = "text";
        text.value = msg;
        text.placeholder = "(message text)";
        text.addEventListener("input", () => (this.draft.messages[i] = text.value));

        const actions = document.createElement("div");
        actions.className = "mx-line-timings";
        actions.appendChild(remove);
        return [text, actions];
      },
    });
  }

  private choiceField<T extends string>(
    label: string,
    value: T,
    options: readonly { value: T; label: string }[],
    onChange: (v: T) => void,
    disabled = false,
  ): HTMLElement {
    const field = document.createElement("label");
    field.className = "mx-field";
    const span = document.createElement("span");
    span.textContent = label;
    const select = document.createElement("select");
    select.disabled = disabled;
    for (const option of options) {
      const item = document.createElement("option");
      item.value = option.value;
      item.textContent = option.label;
      item.selected = option.value === value;
      select.appendChild(item);
    }
    select.addEventListener("change", () => onChange(select.value as T));
    field.append(span, select);
    return field;
  }

  override destroy(): void {
    this.clearPreviewTimer();
    super.destroy();
  }
}
