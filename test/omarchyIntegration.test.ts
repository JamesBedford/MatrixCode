import { execFile, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";

const pythonAvailable = spawnSync("python3", ["--version"], {
  encoding: "utf8",
}).status === 0;
const integrationTest = existsSync("/bin/bash") && pythonAvailable ? it : it.skip;
const executeFile = promisify(execFile);

describe("Omarchy desktop integration", () => {
  integrationTest("installs, restores, and runs the saver against the desktop contract", async () => {
    const result = await executeFile("python3", [
      resolve(process.cwd(), "linux/MatrixCode/tests/OmarchyIntegrationTests.py"),
    ], { encoding: "utf8", timeout: 180_000 });
    expect(result.stderr).toContain("OK");
  }, 190_000);
});
