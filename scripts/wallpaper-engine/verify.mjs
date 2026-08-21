import { resolve } from "node:path";
import { readCatalog, repositoryRoot, validatePackage } from "./lib.mjs";

const packageRoot = process.argv[2]
  ? resolve(process.cwd(), process.argv[2])
  : resolve(repositoryRoot, "dist/wallpaper-engine");
validatePackage(packageRoot, readCatalog());
console.log(`Verified Wallpaper Engine package at ${packageRoot}`);
