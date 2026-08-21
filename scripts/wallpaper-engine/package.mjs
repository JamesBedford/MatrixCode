import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  canonicalJson,
  generateProject,
  readCatalog,
  repositoryRoot,
  validateCatalog,
  validatePackage,
} from "./lib.mjs";

const sourceHtml = resolve(repositoryRoot, "dist/matrixcode.html");
const outputRoot = resolve(repositoryRoot, "dist/wallpaper-engine");
const catalog = readCatalog();
validateCatalog(catalog);
// Do not let files from an older package survive into a release after their source/reference was
// removed. `outputRoot` is a fixed repository-owned build directory, never caller-controlled.
rmSync(outputRoot, { recursive: true, force: true });
mkdirSync(resolve(outputRoot, "icons"), { recursive: true });

// Vite inlines the application, but public PWA assets remain root-relative. WPE
// loads from a local project directory, so make those references package-relative.
const html = readFileSync(sourceHtml, "utf8")
  .replace("<head>", '<head><meta name="matrixcode-wallpaper-engine" content="1">')
  .replaceAll('href="/', 'href="')
  .replaceAll("href='/", "href='")
  .replaceAll('src="/', 'src="')
  .replaceAll("src='/", "src='");
writeFileSync(resolve(outputRoot, "index.html"), html, "utf8");
writeFileSync(resolve(outputRoot, "project.json"), canonicalJson(generateProject(catalog)), "utf8");
copyFileSync(resolve(repositoryRoot, "docs/screenshot.png"), resolve(outputRoot, "preview.png"));
copyFileSync(resolve(repositoryRoot, "public/favicon.svg"), resolve(outputRoot, "favicon.svg"));
copyFileSync(
  resolve(repositoryRoot, "wallpaper-engine/PACKAGE-README.txt"),
  resolve(outputRoot, "README.txt"),
);
copyFileSync(
  resolve(repositoryRoot, "wallpaper-engine/LICENSES.txt"),
  resolve(outputRoot, "LICENSES.txt"),
);

const manifest = JSON.parse(readFileSync(resolve(repositoryRoot, "public/manifest.webmanifest"), "utf8"));
for (const icon of manifest.icons ?? []) {
  if (typeof icon.src === "string") icon.src = icon.src.replace(/^\//, "");
}
writeFileSync(resolve(outputRoot, "manifest.webmanifest"), canonicalJson(manifest), "utf8");
for (const icon of ["apple-touch-icon.png", "icon-192.png", "icon-192-maskable.png", "icon-512.png", "icon-512-maskable.png"]) {
  copyFileSync(resolve(repositoryRoot, `public/icons/${icon}`), resolve(outputRoot, `icons/${icon}`));
}

validatePackage(outputRoot, catalog);
console.log(`Wallpaper Engine package ready at ${outputRoot}`);
