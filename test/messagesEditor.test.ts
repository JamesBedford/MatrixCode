import { afterEach, describe, expect, it, vi } from "vitest";
import { MessagesStore } from "../src/config/messagesStore.ts";
import { MessagesEditor } from "../src/ui/messagesEditor.ts";

class FakeElement {
  readonly tagName: string;
  children: Array<FakeElement | string> = [];
  parentElement: FakeElement | null = null;
  className = "";
  id = "";
  textContent = "";
  title = "";
  tabIndex = -1;
  type = "";
  value = "";
  placeholder = "";
  min = "";
  max = "";
  step = "";
  disabled = false;
  style: Record<string, string> = {};
  private attributes = new Map<string, string>();

  constructor(tagName: string) {
    this.tagName = tagName.toUpperCase();
  }

  appendChild<T extends FakeElement>(child: T): T {
    child.parentElement = this;
    this.children.push(child);
    return child;
  }

  append(...children: Array<FakeElement | string>): void {
    for (const child of children) {
      if (typeof child === "string") this.children.push(child);
      else this.appendChild(child);
    }
  }

  replaceChildren(...children: FakeElement[]): void {
    this.children = [];
    for (const child of children) this.appendChild(child);
  }

  setAttribute(name: string, value: string): void {
    this.attributes.set(name, value);
  }

  getAttribute(name: string): string | null {
    return this.attributes.get(name) ?? null;
  }

  addEventListener(): void {}

  dispatchEvent(): boolean {
    return true;
  }

  remove(): void {
    if (!this.parentElement) return;
    this.parentElement.children = this.parentElement.children.filter((child) => child !== this);
    this.parentElement = null;
  }
}

function descendants(root: FakeElement): FakeElement[] {
  const result: FakeElement[] = [root];
  for (const child of root.children) {
    if (typeof child !== "string") result.push(...descendants(child));
  }
  return result;
}

function fieldLabel(element: FakeElement): string {
  const caption = element.children.find(
    (child): child is FakeElement => typeof child !== "string" && child.tagName === "SPAN",
  );
  return caption?.textContent ?? "";
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("MessagesEditor placement controls", () => {
  it("shows both axes in order and gives Flicker dissolve its own row", () => {
    const parent = new FakeElement("div");
    vi.stubGlobal("document", {
      createElement: (tagName: string) => new FakeElement(tagName),
    });
    vi.stubGlobal("window", {
      addEventListener: () => undefined,
      removeEventListener: () => undefined,
      setTimeout: () => 1,
    });
    vi.stubGlobal("CustomEvent", class {
      constructor(readonly type: string, readonly init?: unknown) {}
    });

    const editor = new MessagesEditor(
      parent as unknown as HTMLElement,
      new MessagesStore(null),
      { onPreview: () => undefined, onSave: () => undefined, onCancel: () => undefined },
      () => [],
    );
    editor.open();

    const labels = descendants(parent)
      .filter((element) => element.tagName === "LABEL")
      .map(fieldLabel);
    expect(labels.filter((label) => /^(Vertical|Horizontal)/.test(label))).toEqual([
      "Vertical position (0 top–100 bottom)",
      "Vertical randomness (%)",
      "Horizontal position (0 left–100 right)",
      "Horizontal randomness (%)",
    ]);

    const horizontalRandomness = labels.indexOf("Horizontal randomness (%)");
    const flicker = labels.indexOf("Flicker dissolve");
    expect(flicker).toBeGreaterThan(horizontalRandomness);

    const flickerField = descendants(parent).find(
      (element) => element.tagName === "LABEL" && fieldLabel(element) === "Flicker dissolve",
    );
    expect(flickerField?.parentElement?.className).toBe("mx-line-timings");
    expect(flickerField?.parentElement?.children).toEqual([flickerField]);

    editor.destroy();
  });
});
