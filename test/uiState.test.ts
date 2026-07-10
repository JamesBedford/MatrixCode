import { describe, expect, it } from "vitest";
import { loadUiState, sanitizeUiState, setActiveSettingsSurface } from "../src/config/uiState.ts";

class MemoryStorage implements Storage {
  private values = new Map<string, string>();

  get length(): number {
    return this.values.size;
  }

  clear(): void {
    this.values.clear();
  }

  getItem(key: string): string | null {
    return this.values.get(key) ?? null;
  }

  key(index: number): string | null {
    return [...this.values.keys()][index] ?? null;
  }

  removeItem(key: string): void {
    this.values.delete(key);
  }

  setItem(key: string, value: string): void {
    this.values.set(key, String(value));
  }
}

describe("ui state", () => {
  it("sanitizes active settings surfaces", () => {
    expect(sanitizeUiState({ activeSettingsSurface: "characters" }).activeSettingsSurface).toBe("characters");
    expect(sanitizeUiState({ activeSettingsSurface: "unknown" }).activeSettingsSurface).toBeNull();
    expect(sanitizeUiState(null).activeSettingsSurface).toBeNull();
  });

  it("persists and clears the active settings surface", () => {
    const storage = new MemoryStorage();

    setActiveSettingsSurface("messages", storage);
    expect(loadUiState(storage).activeSettingsSurface).toBe("messages");

    setActiveSettingsSurface(null, storage);
    expect(storage.getItem("mx-ui-state")).toBeNull();
    expect(loadUiState(storage).activeSettingsSurface).toBeNull();
  });

  it("falls back safely for malformed stored JSON", () => {
    const storage = new MemoryStorage();
    storage.setItem("mx-ui-state", "{not json");
    expect(loadUiState(storage).activeSettingsSurface).toBeNull();
  });
});
