import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const repositoryRoot = fileURLToPath(new URL('..', import.meta.url));
const packagingTest = existsSync('/bin/bash') ? it : it.skip;

describe('Arch Linux packaging', () => {
  packagingTest('stages the shared native sources and checksums, builds, tests, and installs into the package directory', () => {
    const output = execFileSync('/bin/bash', [
      `${repositoryRoot}/linux/MatrixCode/tests/ArchPackagingTests.sh`,
      repositoryRoot,
    ], { encoding: 'utf8' });
    expect(output).toContain('Arch packaging tests passed');
  });
});
