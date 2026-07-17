import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const script = resolve(process.cwd(), "scripts/build-release.sh");
const localBuildScript = resolve(
  process.cwd(),
  "macos/MatrixCodeScreenSaver/build.sh",
);

function runScript(args: string[], environment: NodeJS.ProcessEnv = process.env) {
  return spawnSync("/bin/bash", [script, ...args], {
    cwd: "/",
    encoding: "utf8",
    env: environment,
  });
}

describe("native build script", () => {
  it("has valid Bash syntax", () => {
    const result = spawnSync("/bin/bash", ["-n", script], { encoding: "utf8" });
    expect(result.status, result.stderr).toBe(0);
  });

  it("uses a kernel-backed lock for each build configuration", () => {
    const source = readFileSync(script, "utf8");
    expect(source).toContain('LOCK_FILE="${BUILD_ROOT}/.${CONFIGURATION}.lock"');
    expect(source).toContain('/usr/bin/lockf -s -t 0 9');
  });

  it("documents Debug, Release, Xcode selection, and output paths", () => {
    const result = runScript(["--help"]);
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout).toContain("--debug");
    expect(result.stdout).toContain("--release");
    expect(result.stdout).toContain("--configuration");
    expect(result.stdout).toContain("--skip-notarize");
    expect(result.stdout).toContain("--local-signing");
    expect(result.stdout).toContain("DEVELOPER_DIR");
    expect(result.stdout).toContain("XCODE_APP");
    expect(result.stdout).toContain("build/Debug");
    expect(result.stdout).toContain("build/Release");
    expect(result.stdout).toContain("MatrixCodeScreenSaver/dist");
  });

  it("keeps the native wrapper help focused on local builds", () => {
    const result = spawnSync("/bin/bash", [localBuildScript, "--help"], {
      cwd: "/",
      encoding: "utf8",
    });
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout).toContain("local, ad-hoc-signed");
    expect(result.stdout).toContain("--debug");
    expect(result.stdout).not.toContain("--skip-notarize");
  });

  it("rejects unknown and conflicting options before building", () => {
    const unknown = runScript(["--unknown"]);
    expect(unknown.status).not.toBe(0);
    expect(unknown.stderr).toContain("Unknown option: --unknown");

    const conflicting = runScript(["--debug", "--release"]);
    expect(conflicting.status).not.toBe(0);
    expect(conflicting.stderr).toContain("Choose only one configuration");
  });

  it("rejects invalid configuration names", () => {
    const result = runScript(["--configuration", "Profile"]);
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("Configuration must be Debug or Release");
  });

  it("rejects incompatible signing and notarization options", () => {
    const debugNotarization = runScript(["--debug", "--skip-notarize"]);
    expect(debugNotarization.status).not.toBe(0);
    expect(debugNotarization.stderr).toContain("only valid for Release builds");

    const conflictingRelease = runScript([
      "--release",
      "--local-signing",
      "--skip-notarize",
    ]);
    expect(conflictingRelease.status).not.toBe(0);
    expect(conflictingRelease.stderr).toContain("either --local-signing or --skip-notarize");
  });

  it("validates an explicit developer directory", () => {
    const result = runScript(["--debug"], {
      ...process.env,
      DEVELOPER_DIR: "/definitely/not/Xcode/Contents/Developer",
      XCODE_APP: "",
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("DEVELOPER_DIR is not a valid Xcode developer directory");
  });
});
