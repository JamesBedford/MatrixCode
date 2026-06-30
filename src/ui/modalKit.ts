/**
 * Shared scaffolding for the app's centered modal editors (intro, messages). Owns the backdrop +
 * dialog, the capture-phase keydown/Escape lifecycle, the vanilla-DOM widget factory, the footer
 * builder, and a generic reorderable list — so each editor only supplies its own `build()` body.
 * All styling comes from the global `.mx-modal*` / `.mx-line*` / `.mx-field` classes in styles.css.
 */
export abstract class ModalEditor {
  readonly el: HTMLDivElement; // backdrop
  protected readonly dialog: HTMLDivElement;
  protected isOpen = false;
  protected previewing = false;

  constructor(parent: HTMLElement, ariaLabel: string) {
    this.el = document.createElement("div");
    this.el.className = "mx-modal-backdrop";
    this.el.style.display = "none";
    this.el.addEventListener("click", (e) => {
      if (e.target === this.el) this.requestClose();
    });

    this.dialog = document.createElement("div");
    this.dialog.className = "mx-modal";
    this.dialog.setAttribute("role", "dialog");
    this.dialog.setAttribute("aria-modal", "true");
    this.dialog.setAttribute("aria-label", ariaLabel);
    this.el.appendChild(this.dialog);

    parent.appendChild(this.el);
    // Capture phase so this runs before app.ts's window keydown handler; while the editor is open we
    // swallow shortcuts (incl. f/h) and handle Escape ourselves.
    window.addEventListener("keydown", this.onKeyDownCapture, true);
  }

  /** Render the dialog body. Called by the subclass on open and on internal re-renders. */
  protected abstract build(): void;

  /** Invoked by Escape and click-outside; subclasses implement as their cancel(). */
  protected abstract requestClose(): void;

  protected onKeyDownCapture = (e: KeyboardEvent): void => {
    if (!this.isOpen || this.previewing) return;
    e.stopPropagation();
    if (e.key === "Escape") {
      e.preventDefault();
      this.requestClose();
    }
  };

  protected show(): void {
    this.el.style.display = "grid";
    this.isOpen = true;
    this.previewing = false;
  }

  protected hide(): void {
    this.el.style.display = "none";
    this.isOpen = false;
  }

  /** Hide the modal so a preview can play unobstructed over the rain. */
  protected beginPreview(): void {
    this.previewing = true;
    this.el.style.display = "none";
  }

  /** Restore the modal after a preview ends. */
  protected restoreFromPreview(): void {
    if (!this.previewing) return;
    this.previewing = false;
    this.el.style.display = "grid";
  }

  destroy(): void {
    window.removeEventListener("keydown", this.onKeyDownCapture, true);
    this.el.remove();
  }

  // ---- shared vanilla-DOM widget factory ----

  protected heading(tag: "h2" | "h3", text: string): HTMLElement {
    const h = document.createElement(tag);
    h.textContent = text;
    return h;
  }

  protected numberField(
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

  protected secondsField(label: string, valueMs: number, onChangeMs: (ms: number) => void): HTMLElement {
    return this.numberField(label, valueMs / 1000, 0, 60, 0.1, (s) => onChangeMs(Math.round(s * 1000)));
  }

  protected toggleField(label: string, value: boolean, onChange: (v: boolean) => void): HTMLElement {
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

  protected iconButton(label: string, title: string, onClick: () => void): HTMLButtonElement {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "mx-icon-btn";
    b.title = title;
    b.setAttribute("aria-label", title);
    b.textContent = label;
    b.addEventListener("click", onClick);
    return b;
  }

  protected textButton(label: string, className: string, onClick: () => void): HTMLButtonElement {
    const b = document.createElement("button");
    b.type = "button";
    b.className = className;
    b.textContent = label;
    b.addEventListener("click", onClick);
    return b;
  }

  /** Build a right-aligned footer of buttons (default class `mx-btn`; pass `mx-btn mx-reset` to left-align). */
  protected footer(buttons: { label: string; className?: string; onClick: () => void }[]): HTMLElement {
    const footer = document.createElement("div");
    footer.className = "mx-modal-footer";
    for (const b of buttons) footer.appendChild(this.textButton(b.label, b.className ?? "mx-btn", b.onClick));
    return footer;
  }

  /**
   * Render an add/remove/reorder list into `container`. The kit owns each row's `.mx-line` wrapper, the
   * up/down reorder column, and the ✕ remove button (disabled at `minItems`); `renderBody` supplies the
   * row's body nodes and decides where the passed-in `remove` button sits. Mutates `items` in place and
   * re-renders itself on reorder/remove.
   */
  protected reorderableList<T>(opts: {
    container: HTMLElement;
    items: T[];
    minItems: number;
    renderBody: (item: T, index: number, remove: HTMLButtonElement) => Node[];
  }): void {
    const { container, items, minItems, renderBody } = opts;
    container.replaceChildren();
    items.forEach((item, i) => {
      const row = document.createElement("div");
      row.className = "mx-line";

      const reorder = document.createElement("div");
      reorder.className = "mx-line-reorder";
      const up = this.iconButton("↑", "Move up", () => {
        if (i === 0) return;
        [items[i - 1], items[i]] = [items[i]!, items[i - 1]!];
        this.reorderableList(opts);
      });
      up.disabled = i === 0;
      const down = this.iconButton("↓", "Move down", () => {
        if (i === items.length - 1) return;
        [items[i + 1], items[i]] = [items[i]!, items[i + 1]!];
        this.reorderableList(opts);
      });
      down.disabled = i === items.length - 1;
      reorder.append(up, down);
      row.appendChild(reorder);

      const remove = this.iconButton("✕", "Remove", () => {
        items.splice(i, 1);
        this.reorderableList(opts);
      });
      remove.disabled = items.length <= minItems;

      for (const node of renderBody(item, i, remove)) row.appendChild(node);
      container.appendChild(row);
    });
  }
}
