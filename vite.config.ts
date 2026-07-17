import { defineConfig } from "vitest/config";
import type { Plugin } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

// Port is registered with LanternPad (LAN service discovery). Update here if it changes.
export const DEV_PORT = 5188;

// Emit the inlined bundle as matrixcode.html instead of index.html.
function renameOutput(): Plugin {
  return {
    name: "rename-output-html",
    enforce: "post",
    generateBundle(_options, bundle) {
      const html = bundle["index.html"];
      if (html) {
        delete bundle["index.html"];
        html.fileName = "matrixcode.html";
        bundle["matrixcode.html"] = html;
      }
    },
  };
}

export default defineConfig({
  plugins: [viteSingleFile(), renameOutput()],
  server: {
    port: DEV_PORT,
    host: true,
    strictPort: false,
  },
  build: {
    target: "es2022",
  },
  test: {
    globals: true,
    environment: "node",
    include: ["test/**/*.test.ts"],
    // The simulation suites are CPU-bound and run files in parallel, so a test that
    // needs ~1s alone can sit far longer waiting behind its siblings. The default 5s
    // turns that contention into spurious failures; this keeps the gate meaningful
    // for genuine hangs while leaving room for a loaded machine.
    testTimeout: 30000,
  },
});
