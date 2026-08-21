import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const projectPath = resolve(process.cwd(), "wallpaper-engine/project.json");
const generatorPath = resolve(process.cwd(), "scripts/wallpaper-engine/generate-project.mjs");

interface ManifestProperty {
  type: string;
  order: number;
  mode?: string;
}

function project() {
  return JSON.parse(readFileSync(projectPath, "utf8")) as {
    type: string;
    file: string;
    preview: string;
    general: { properties: Record<string, ManifestProperty> };
  };
}

describe("Wallpaper Engine generated project", () => {
  it("is current with the canonical property catalog", () => {
    const result = spawnSync(process.execPath, [generatorPath, "--check"], {
      cwd: process.cwd(),
      encoding: "utf8",
    });
    expect(result.status, result.stderr).toBe(0);
  });

  it("is a web project with fixed slots and offline package entry names", () => {
    const manifest = project();
    const properties = manifest.general.properties;
    expect(manifest).toMatchObject({ type: "web", file: "index.html", preview: "preview.png" });
    expect(Object.keys(properties)).toHaveLength(163);
    expect(Object.keys(properties).every((key) => /^[a-z0-9]+$/.test(key))).toBe(true);
    expect(Object.values(properties).filter(({ type }) => type === "group")).toHaveLength(8);
    expect(Object.keys(properties).filter((key) => /^intro\d{2}/.test(key))).toHaveLength(48);
    expect(Object.keys(properties).filter((key) => /^message\d{2}/.test(key))).toHaveLength(24);
    expect(Object.keys(properties).filter((key) => /^moment\d{2}/.test(key))).toHaveLength(36);
    expect(properties.imagesinglefile).toBeUndefined();
    expect(properties.imagesdirectory).toMatchObject({ type: "directory", mode: "fetchall" });
  });

  it("keeps every order stable and unique", () => {
    const properties = Object.values(project().general.properties);
    const orders = properties.map(({ order }) => order);
    expect(new Set(orders).size).toBe(orders.length);
  });
});
