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
    super(parent, "Edit messages");
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

  /** Reflect an externally-toggled "Show messages" (the keyboard shortcut) into an open editor, keeping other edits. */
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

    this.dialog.appendChild(this.heading("h2", "Edit messages"));
    this.dialog.appendChild(this.heading("h3", "Messages"));

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
    this.dialog.appendChild(hint);

    this.listEl = document.createElement("div");
    this.dialog.appendChild(this.listEl);
    this.renderMessages();

    const add = this.textButton("+ Add message", "mx-btn mx-modal-add", () => {
      this.draft.messages.push("");
      this.renderMessages();
    });
    this.dialog.appendChild(add);

    this.dialog.appendChild(this.heading("h3", "Behaviour"));
    const behaviour = document.createElement("div");
    behaviour.className = "mx-line-timings";
    const showMessages = this.toggleField("Show messages", this.draft.enabled, (v) => (this.draft.enabled = v));
    showMessages.title = "Show messages (N)";
    behaviour.appendChild(showMessages);
    behaviour.appendChild(this.choiceField<MessageLayout>(
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
    behaviour.appendChild(this.choiceField<MessageDirection>(
      "Drop direction",
      this.draft.messageDirection,
      [
        { value: "topToBottom", label: "Top to bottom" },
        { value: "bottomToTop", label: "Bottom to top" },
      ],
      (v) => (this.draft.messageDirection = v),
      this.draft.messageLayout !== "drop",
    ));
    behaviour.appendChild(this.secondsField("Show one every (s)", this.draft.frequencyMs, (ms) => (this.draft.frequencyMs = ms)));
    behaviour.appendChild(this.secondsField("Each stays for (s)", this.draft.persistenceMs, (ms) => (this.draft.persistenceMs = ms)));
    behaviour.appendChild(this.secondsField("Appear over (s)", this.draft.appearMs, (ms) => (this.draft.appearMs = ms)));
    behaviour.appendChild(this.secondsField("Disappear over (s)", this.draft.disappearMs, (ms) => (this.draft.disappearMs = ms)));
    const dropLayout = this.draft.messageLayout === "drop";
    behaviour.appendChild(this.percentField(
      dropLayout ? "Horizontal position (0 left–100 right)" : "Vertical position (0 top–100 bottom)",
      this.draft.verticalPosition,
      (f) => (this.draft.verticalPosition = f),
    ));
    behaviour.appendChild(this.percentField(
      dropLayout ? "Horizontal randomness (%)" : "Vertical randomness (%)",
      this.draft.verticalJitter,
      (f) => (this.draft.verticalJitter = f),
    ));
    behaviour.appendChild(this.toggleField("Flicker dissolve", this.draft.flickerOut, (v) => (this.draft.flickerOut = v)));
    behaviour.appendChild(this.toggleField("Brightness fade", this.draft.brightnessFade, (v) => (this.draft.brightnessFade = v)));
    this.dialog.appendChild(behaviour);

    this.dialog.appendChild(this.footer([
      { label: "Reset to default", className: "mx-btn mx-reset", onClick: () => { this.draft = cloneMessages(DEFAULT_MESSAGES); this.build(); } },
      { label: "Cancel", onClick: () => this.cancel() },
      { label: "Preview", onClick: () => this.preview() },
      { label: "Save", onClick: () => this.save() },
    ]));
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
