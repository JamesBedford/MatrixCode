import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
export const catalogPath = resolve(repositoryRoot, "wallpaper-engine/property-spec.json");
export const checkedInProjectPath = resolve(repositoryRoot, "wallpaper-engine/project.json");

export function readCatalog() {
  return JSON.parse(readFileSync(catalogPath, "utf8"));
}

function slotToken(index) {
  return String(index + 1).padStart(2, "0");
}

function replaceSlotToken(value, slot) {
  return typeof value === "string" ? value.replaceAll("{slot}", slot) : value;
}

export function expandCatalog(catalog) {
  const properties = [];
  for (const group of catalog.groups ?? []) {
    for (const property of group.properties ?? []) {
      properties.push({ ...property, domain: property.domain ?? group.domain });
    }
    const slots = group.slots;
    if (!slots) continue;
    for (let index = 0; index < slots.count; index += 1) {
      const slot = slotToken(index);
      for (const field of slots.fields) {
        const value = field.values?.[index] ?? field.value;
        properties.push({
          ...field,
          key: `${slots.prefix}${slot}${field.suffix}`,
          order: slots.orderStart + index * slots.orderStride + field.orderOffset,
          text: replaceSlotToken(field.text, slot),
          value,
          condition: replaceSlotToken(field.condition, slot),
          domain: field.domain ?? group.domain,
        });
      }
    }
  }
  return properties;
}

function manifestProperty(property) {
  const out = {};
  for (const [key, value] of Object.entries(property)) {
    if (
      key === "key" ||
      key === "domain" ||
      key === "suffix" ||
      key === "orderOffset" ||
      key === "values" ||
      value === undefined
    ) {
      continue;
    }
    out[key] = value;
  }
  return out;
}

export function generateProject(catalog) {
  const entries = [];
  for (const group of catalog.groups) {
    entries.push([
      group.key,
      { order: group.order, text: group.text, type: "group" },
    ]);
  }
  for (const property of expandCatalog(catalog)) {
    entries.push([property.key, manifestProperty(property)]);
  }
  entries.sort((left, right) => left[1].order - right[1].order || left[0].localeCompare(right[0]));
  const metadata = catalog.metadata;
  return {
    title: metadata.title,
    description: metadata.description,
    file: metadata.file,
    general: { properties: Object.fromEntries(entries) },
    preview: metadata.preview,
    tags: metadata.tags,
    type: metadata.type,
    visibility: metadata.visibility,
  };
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function validateProperty(property, keys, orders) {
  assert(/^[a-z0-9]+$/.test(property.key), `Invalid property key: ${property.key}`);
  assert(!keys.has(property.key), `Duplicate property key: ${property.key}`);
  assert(Number.isInteger(property.order), `Non-integer order for ${property.key}`);
  assert(!orders.has(property.order), `Duplicate property order: ${property.order}`);
  assert(typeof property.text === "string" && !property.text.includes("{slot}"), `Bad label for ${property.key}`);
  assert(
    ["bool", "color", "combo", "directory", "file", "slider", "textinput"].includes(property.type),
    `Unsupported property type for ${property.key}`,
  );
  if (property.type === "bool") assert(typeof property.value === "boolean", `Bad bool default: ${property.key}`);
  if (property.type === "slider") {
    assert(Number.isFinite(property.value), `Bad slider default: ${property.key}`);
    assert(Number.isFinite(property.min) && Number.isFinite(property.max), `Missing slider bounds: ${property.key}`);
    assert(property.min <= property.value && property.value <= property.max, `Out-of-range default: ${property.key}`);
  }
  if (property.type === "combo") {
    assert(Array.isArray(property.options) && property.options.length > 0, `Missing combo options: ${property.key}`);
    assert(property.options.some((option) => option.value === property.value), `Bad combo default: ${property.key}`);
  }
  if (["color", "directory", "file", "textinput"].includes(property.type)) {
    assert(typeof property.value === "string", `Bad string default: ${property.key}`);
  }
  if (property.type === "directory") {
    assert(property.mode === "fetchall", `Directory must use fetchall: ${property.key}`);
  }
  keys.add(property.key);
  orders.add(property.order);
}

export function validateCatalog(catalog) {
  assert(catalog.version === 1, "Unsupported property catalog version");
  assert(catalog.directoryImageLimit === 64, "Directory image limit must be 64");
  assert(catalog.metadata?.type === "web", "Wallpaper type must be web");
  assert(catalog.metadata?.file === "index.html", "Wallpaper entry must be index.html");
  assert(Array.isArray(catalog.groups) && catalog.groups.length === 8, "Expected eight property groups");

  const keys = new Set();
  const orders = new Set();
  for (const group of catalog.groups) {
    assert(/^[a-z0-9]+$/.test(group.key), `Invalid group key: ${group.key}`);
    assert(!keys.has(group.key), `Duplicate group key: ${group.key}`);
    assert(!orders.has(group.order), `Duplicate group order: ${group.order}`);
    keys.add(group.key);
    orders.add(group.order);
  }
  const properties = expandCatalog(catalog);
  for (const property of properties) validateProperty(property, keys, orders);

  for (const [prefix, fields] of [
    ["intro", ["enabled", "text", "holdseconds", "pauseseconds"]],
    ["message", ["enabled", "text"]],
    ["moment", ["enabled", "name", "targetlocal"]],
  ]) {
    for (let index = 1; index <= 12; index += 1) {
      const slot = String(index).padStart(2, "0");
      for (const field of fields) {
        assert(keys.has(`${prefix}${slot}${field}`), `Missing ${prefix} slot ${slot} ${field}`);
      }
    }
  }
  const imageDirectory = properties.find((property) => property.key === "imagesdirectory");
  assert(imageDirectory?.type === "directory" && imageDirectory.mode === "fetchall", "Missing fetchall image directory");

  for (const property of properties) {
    for (const match of property.condition?.matchAll(/([a-z][a-z0-9]*)\.value/g) ?? []) {
      assert(keys.has(match[1]), `Unknown condition key ${match[1]} in ${property.key}`);
    }
  }
  return properties;
}

export function canonicalJson(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

export function validateProject(project, catalog) {
  validateCatalog(catalog);
  const expected = canonicalJson(generateProject(catalog));
  const actual = canonicalJson(project);
  assert(actual === expected, "project.json does not match property-spec.json");
}

export function validatePackage(packageRoot, catalog) {
  const projectPath = resolve(packageRoot, "project.json");
  assert(existsSync(projectPath), "Package is missing project.json");
  const project = JSON.parse(readFileSync(projectPath, "utf8"));
  validateProject(project, catalog);
  for (const relative of [
    project.file,
    project.preview,
    "README.txt",
    "LICENSES.txt",
    "favicon.svg",
    "manifest.webmanifest",
  ]) {
    assert(existsSync(resolve(packageRoot, relative)), `Package is missing ${relative}`);
  }
  const licenses = readFileSync(resolve(packageRoot, "LICENSES.txt"), "utf8");
  assert(
    licenses.includes("Copyright (c) 2026 James Bedford") &&
      licenses.includes("Copyright 2019 Gregg Tavares"),
    "Package license notices are incomplete",
  );

  const html = readFileSync(resolve(packageRoot, project.file), "utf8");
  assert(
    html.includes('<meta name="matrixcode-wallpaper-engine" content="1">'),
    "Package HTML is missing the Wallpaper Engine host marker",
  );
  const references = [...html.matchAll(/(?:src|href)=["']([^"']+)["']/gi)].map((match) => match[1]);
  for (const reference of references) {
    if (/^(?:#|data:|blob:|file:)/i.test(reference)) continue;
    assert(!/^(?:https?:)?\/\//i.test(reference), `Network reference in index.html: ${reference}`);
    assert(!reference.startsWith("/"), `Root-relative reference in index.html: ${reference}`);
    assert(existsSync(resolve(packageRoot, reference)), `Missing local reference from index.html: ${reference}`);
  }
  return { project, references };
}
