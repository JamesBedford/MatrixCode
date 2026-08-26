import { readFileSync, writeFileSync } from "node:fs";
import {
  canonicalJson,
  checkedInProjectPath,
  generateProject,
  readCatalog,
  validateCatalog,
} from "./lib.mjs";

const catalog = readCatalog();
validateCatalog(catalog);
const generated = canonicalJson(generateProject(catalog));
const mode = process.argv[2] ?? "--check";

if (mode === "--write") {
  writeFileSync(checkedInProjectPath, generated, "utf8");
  console.log(`Wrote ${checkedInProjectPath}`);
} else if (mode === "--check") {
  // Git may materialize this generated JSON with CRLF on Windows. Keep checking the canonical
  // formatting and final newline while treating the platform's line-ending conversion as equal.
  const existing = readFileSync(checkedInProjectPath, "utf8").replaceAll("\r\n", "\n");
  if (existing !== generated) {
    throw new Error("wallpaper-engine/project.json is stale; run generate-project.mjs --write");
  }
  console.log("Wallpaper Engine project.json is current.");
} else {
  throw new Error("Usage: node scripts/wallpaper-engine/generate-project.mjs [--check|--write]");
}
