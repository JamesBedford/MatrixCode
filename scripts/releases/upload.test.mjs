import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFile, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { parseOptions, prepareRelease, uploadRelease } from './upload.mjs';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');

async function fixture(context) {
  const base = await realpath(await mkdtemp(path.join(tmpdir(), 'matrixcode-upload-test-')));
  context.after(() => rm(base, { recursive: true, force: true }));
  const source = path.join(base, 'artifacts');
  const root = path.join(base, 'public_html');
  const bin = path.join(base, 'bin');
  await Promise.all([mkdir(source), mkdir(path.join(root, 'matrixcode'), { recursive: true }), mkdir(bin)]);
  await writeFile(path.join(root, 'matrixcode/index.html'), 'existing browser app');
  const filename = 'MatrixCode-1.1.0-macos.dmg';
  const bytes = Buffer.from('test disk image');
  await writeFile(path.join(source, filename), bytes);
  await writeFile(path.join(source, 'SHA256SUMS.txt'), `${digest(bytes)}  ${filename}\n`);
  const arguments_ = ['--version', '1.1.0', '--directory', source, '--artifact', filename, '--web-root', root];
  // The remote host uses GNU mv. This test adapter models its -T -n directory
  // rename on macOS, including refusing to replace an existing destination.
  const mv = `#!${process.execPath}\nimport { existsSync, mkdirSync, renameSync, writeFileSync } from 'node:fs';\nconst args=process.argv.slice(2);\nif(args.slice(0,3).join(' ')!=='-T -n --')process.exit(2);\nif(process.env.MATRIXCODE_TEST_CREATE_ON_MV==='1'){mkdirSync(args[4]);writeFileSync(args[4]+'/sentinel','concurrent release');}\nif(!existsSync(args[4]))renameSync(args[3],args[4]);\n`;
  await writeFile(path.join(bin, 'mv'), mv, { mode: 0o755 });
  return { base, source, root, bin, filename, arguments_ };
}

function shell(command, input, environment) {
  return new Promise((resolve, reject) => {
    const child = spawn('/bin/sh', ['-c', command], { env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', bytes => { stdout += bytes; });
    child.stderr.on('data', bytes => { stderr += bytes; });
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve(stdout) : reject(new Error(stderr || stdout)));
    child.stdin.end(input);
  });
}

function remoteAdapter(data, { tamper = false, concurrentRelease = false, renameCollision = false } = {}) {
  const calls = [];
  const run = async (command, arguments_, input) => {
    calls.push({ command, arguments_, input });
    if (command === 'ssh') {
      return shell(arguments_.at(-1), input, { ...process.env, PATH: `${data.bin}:${process.env.PATH}`, MATRIXCODE_TEST_CREATE_ON_MV: renameCollision ? '1' : '' });
    }
    assert.equal(command, 'sftp');
    for (const line of input.trimEnd().split('\n')) {
      const match = /^put ("(?:[^"\\]|\\.)*") ("(?:[^"\\]|\\.)*")$/.exec(line);
      assert.ok(match, `Unexpected SFTP command: ${line}`);
      await copyFile(JSON.parse(match[1]), JSON.parse(match[2]));
      if (tamper && JSON.parse(match[2]).endsWith(data.filename)) await writeFile(JSON.parse(match[2]), 'corrupt bytes');
    }
    if (concurrentRelease) {
      const destination = path.join(data.root, 'matrixcode/releases/v1.1.0');
      await mkdir(destination);
      await writeFile(path.join(destination, 'sentinel'), 'concurrent release');
    }
    return '';
  };
  return { run, calls, write: () => {} };
}

test('rejects unsafe versions, filenames, and destination paths', () => {
  const base = ['--version', '1.1.0', '--directory', '/tmp/artifacts', '--artifact', 'MatrixCode.zip'];
  for (const version of ['../1.1.0', '01.1.0', '1.1', '1.1.0-01', '1.1.0;touch']) {
    assert.throws(() => parseOptions(['--version', version, ...base.slice(2)], {}), /semantic version/);
  }
  for (const filename of ['../MatrixCode.zip', 'index.html', '.hidden.zip', 'app.zip;touch']) {
    assert.throws(() => parseOptions([...base.slice(0, 4), '--artifact', filename], {}), /Unsupported artifact/);
  }
  for (const root of ['/', '/tmp/../public_html', '/tmp/public_html/']) {
    assert.throws(() => parseOptions([...base, '--web-root', root], {}), /Web root/);
  }
  assert.equal(parseOptions(['--version', 'v1.1.0-rc.1+build.2', ...base.slice(2)], {}).version, '1.1.0-rc.1+build.2');
});

test('refuses missing, mismatched, or extra checksum entries', async context => {
  const data = await fixture(context);
  const options = parseOptions(data.arguments_, {});
  await writeFile(path.join(data.source, 'SHA256SUMS.txt'), `${'0'.repeat(64)}  ${data.filename}\n`);
  await assert.rejects(prepareRelease(options), /mismatched checksum/);
  await writeFile(path.join(data.source, 'SHA256SUMS.txt'), `${digest('test disk image')}  ${data.filename}\n${digest('other')}  Other.zip\n`);
  await assert.rejects(prepareRelease(options), /no extra entries/);
  await writeFile(path.join(data.source, 'SHA256SUMS.txt'), '');
  await assert.rejects(prepareRelease(options), /one SHA-256 entry/);
});

test('refuses symlink artifacts', async context => {
  const data = await fixture(context);
  await rm(path.join(data.source, data.filename));
  await symlink(path.join(data.root, 'matrixcode/index.html'), path.join(data.source, data.filename));
  await assert.rejects(prepareRelease(parseOptions(data.arguments_, {})), /regular file/);
});

test('dry run checks remotely without creating staging or a releases directory', async context => {
  const data = await fixture(context);
  const plan = await prepareRelease(parseOptions([...data.arguments_, '--dry-run'], {}));
  const adapter = remoteAdapter(data);
  await uploadRelease(plan, adapter);
  assert.equal(adapter.calls.length, 1);
  assert.equal(adapter.calls[0].command, 'ssh');
  assert.ok(adapter.calls[0].arguments_.includes('StrictHostKeyChecking=yes'));
  await assert.rejects(lstat(path.join(data.root, 'matrixcode/releases')), { code: 'ENOENT' });
});

test('publishes only verified artifacts together and preserves the existing app', async context => {
  const data = await fixture(context);
  const plan = await prepareRelease(parseOptions(data.arguments_, {}));
  await uploadRelease(plan, remoteAdapter(data));
  const release = path.join(data.root, 'matrixcode/releases/v1.1.0');
  assert.deepEqual((await readdir(release)).sort(), [data.filename, 'SHA256SUMS.txt'].sort());
  assert.equal(await readFile(path.join(release, data.filename), 'utf8'), 'test disk image');
  assert.equal(await readFile(path.join(data.root, 'matrixcode/index.html'), 'utf8'), 'existing browser app');
  assert.deepEqual(await readdir(path.dirname(release)), ['v1.1.0']);
  await assert.rejects(uploadRelease(plan, remoteAdapter(data)), /immutable releases cannot be overwritten/);
});

test('remote checksum mismatch prevents publication and removes its own staging files', async context => {
  const data = await fixture(context);
  const plan = await prepareRelease(parseOptions(data.arguments_, {}));
  await assert.rejects(uploadRelease(plan, remoteAdapter(data, { tamper: true })), /checksum mismatch/);
  assert.deepEqual(await readdir(path.join(data.root, 'matrixcode/releases')), []);
});

test('a concurrent release is preserved and the unpublished upload is cleaned up', async context => {
  const data = await fixture(context);
  const plan = await prepareRelease(parseOptions(data.arguments_, {}));
  await assert.rejects(uploadRelease(plan, remoteAdapter(data, { concurrentRelease: true })), /immutable releases cannot be overwritten/);
  const releases = path.join(data.root, 'matrixcode/releases');
  assert.deepEqual(await readdir(releases), ['v1.1.0']);
  assert.equal(await readFile(path.join(releases, 'v1.1.0/sentinel'), 'utf8'), 'concurrent release');
});

test('a release created at the final rename is preserved without a nested staging directory', async context => {
  const data = await fixture(context);
  const plan = await prepareRelease(parseOptions(data.arguments_, {}));
  await assert.rejects(uploadRelease(plan, remoteAdapter(data, { renameCollision: true })), /nothing was overwritten/);
  const releases = path.join(data.root, 'matrixcode/releases');
  assert.deepEqual(await readdir(releases), ['v1.1.0']);
  assert.deepEqual(await readdir(path.join(releases, 'v1.1.0')), ['sentinel']);
});

test('optional manifest and release notes are included only with matching checksums', async context => {
  const data = await fixture(context);
  await writeFile(path.join(data.source, 'release.json'), '{"version":"1.1.0"}\n');
  await writeFile(path.join(data.source, 'RELEASE_NOTES.md'), 'Release notes\n');
  const options = parseOptions([...data.arguments_, '--manifest', '--notes'], {});
  await assert.rejects(prepareRelease(options), /Missing or mismatched checksum: release.json/);
  const manifest = await readFile(path.join(data.source, 'release.json'));
  const notes = await readFile(path.join(data.source, 'RELEASE_NOTES.md'));
  await writeFile(path.join(data.source, 'SHA256SUMS.txt'), `${digest('test disk image')}  ${data.filename}\n${digest(manifest)}  release.json\n${digest(notes)}  RELEASE_NOTES.md\n`);
  const plan = await prepareRelease(options);
  assert.deepEqual(plan.files.map(file => file.filename), [data.filename, 'release.json', 'RELEASE_NOTES.md', 'SHA256SUMS.txt']);
});
