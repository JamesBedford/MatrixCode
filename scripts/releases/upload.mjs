import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { copyFile, lstat, mkdtemp, readFile, rm } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const artifactExtensions = new Set(['.dmg', '.deb', '.msi', '.zip']);
const checksumFilename = 'SHA256SUMS.txt';
const help = `Usage: node scripts/releases/upload.mjs --version VERSION --directory DIR --artifact NAME [--artifact NAME ...] [--dry-run]

Required: DIR/SHA256SUMS.txt must list exactly the selected artifacts and metadata.
Optional: --manifest (release.json), --notes (RELEASE_NOTES.md), --identity PATH,
          --host HOST, --user USER, --port PORT, --web-root PATH, --origin URL.
Defaults: julimbob@kamino.krystal.uk:722, /home/julimbob/public_html,
          https://julimbob.com. Connection options also accept environment variables
          MATRIXCODE_RELEASE_HOST, _USER, _PORT, _WEB_ROOT, _IDENTITY, _ORIGIN.
Dry runs validate local files and perform read-only remote checks.
Publication creates /matrixcode/releases/vVERSION/ and never replaces a release.
`;

function safeFilename(value) {
  return typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._+-]{0,199}$/.test(value);
}

function releaseVersion(value) {
  const version = value.replace(/^v/, '');
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/.exec(version);
  if (!match || version.length > 80 || match[4]?.split('.').some(part => /^\d+$/.test(part) && /^0\d/.test(part))) {
    throw new Error('Version must be a valid semantic version, optionally prefixed with v.');
  }
  return version;
}

export function parseOptions(arguments_, environment = process.env) {
  const options = {
    host: environment.MATRIXCODE_RELEASE_HOST || 'kamino.krystal.uk',
    user: environment.MATRIXCODE_RELEASE_USER || 'julimbob',
    port: environment.MATRIXCODE_RELEASE_PORT || '722',
    webRoot: environment.MATRIXCODE_RELEASE_WEB_ROOT || '/home/julimbob/public_html',
    identity: environment.MATRIXCODE_RELEASE_IDENTITY || '',
    origin: environment.MATRIXCODE_RELEASE_ORIGIN || 'https://julimbob.com',
    artifacts: [], dryRun: false, manifest: false, notes: false,
  };
  const values = new Map([['--version', 'version'], ['--directory', 'directory'], ['--host', 'host'], ['--user', 'user'], ['--port', 'port'], ['--web-root', 'webRoot'], ['--identity', 'identity'], ['--origin', 'origin']]);
  const supplied = new Set();
  for (let index = 0; index < arguments_.length; index++) {
    const argument = arguments_[index];
    if (argument === '--help') return { help: true };
    if (['--dry-run', '--manifest', '--notes'].includes(argument)) {
      options[{ '--dry-run': 'dryRun', '--manifest': 'manifest', '--notes': 'notes' }[argument]] = true;
    } else if (argument === '--artifact' || values.has(argument)) {
      const value = arguments_[++index];
      if (!value || value.startsWith('--') || /[\u0000-\u001f\u007f]/.test(value)) throw new Error(`Missing or invalid value for ${argument}.`);
      if (argument === '--artifact') options.artifacts.push(value);
      else {
        if (supplied.has(argument)) throw new Error(`Duplicate option: ${argument}.`);
        supplied.add(argument);
        options[values.get(argument)] = value;
      }
    } else throw new Error(`Unknown option: ${argument}.`);
  }
  if (!options.version || !options.directory || !options.artifacts.length) throw new Error('Provide --version, --directory, and at least one --artifact.');
  options.version = releaseVersion(options.version);
  if (new Set(options.artifacts).size !== options.artifacts.length) throw new Error('Duplicate artifact name.');
  for (const filename of options.artifacts) {
    if (!safeFilename(filename) || !artifactExtensions.has(path.posix.extname(filename))) throw new Error(`Unsupported artifact: ${filename}. Select a .dmg, .deb, .msi, or .zip basename.`);
  }
  if (!/^[a-zA-Z0-9][a-zA-Z0-9.-]*$/.test(options.host) || !/^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$/.test(options.user)) throw new Error('Invalid SSH hostname or username.');
  if (!/^\d+$/.test(String(options.port)) || Number(options.port) < 1 || Number(options.port) > 65535) throw new Error('SSH port must be an integer from 1 to 65535.');
  if (!/^\/(?:[a-zA-Z0-9_-]+\/)*[a-zA-Z0-9_-]+$/.test(options.webRoot)) throw new Error('Web root must be an absolute directory without symlinks or traversal components.');
  const origin = new URL(options.origin);
  if (origin.protocol !== 'https:' || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) throw new Error('Origin must be an HTTPS origin without a path or credentials.');
  options.origin = origin.origin;
  options.directory = path.resolve(options.directory);
  if (options.identity) options.identity = path.resolve(options.identity.startsWith('~/') ? path.join(homedir(), options.identity.slice(2)) : options.identity);
  return options;
}

async function sha256(filename) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(filename)) hash.update(chunk);
  return hash.digest('hex');
}

export async function prepareRelease(options) {
  if (!(await lstat(options.directory)).isDirectory()) throw new Error('Artifact directory must be a regular directory, not a symlink.');
  const filenames = [...options.artifacts, ...(options.manifest ? ['release.json'] : []), ...(options.notes ? ['RELEASE_NOTES.md'] : [])];
  const files = [];
  for (const filename of [...filenames, checksumFilename]) {
    const localPath = path.join(options.directory, filename);
    const stat = await lstat(localPath);
    if (!stat.isFile() || stat.nlink !== 1) throw new Error(`Artifact must be a regular file without symlinks or hard links: ${filename}.`);
    files.push({ filename, localPath, size: stat.size, checksum: await sha256(localPath) });
  }
  const checksums = new Map();
  const lines = (await readFile(path.join(options.directory, checksumFilename), 'utf8')).trimEnd().split(/\r?\n/);
  for (const line of lines) {
    const match = /^([a-f0-9]{64})  ([a-zA-Z0-9][a-zA-Z0-9._+-]{0,199})$/.exec(line);
    if (!match || checksums.has(match[2]) || !filenames.includes(match[2])) throw new Error('SHA256SUMS.txt must contain one SHA-256 entry for each selected artifact and metadata file, with no extra entries.');
    checksums.set(match[2], match[1]);
  }
  for (const file of files.filter(file => file.filename !== checksumFilename)) {
    if (checksums.get(file.filename) !== file.checksum) throw new Error(`Missing or mismatched checksum: ${file.filename}.`);
  }
  return { ...options, files };
}

function shellQuote(value) { return `'${String(value).replaceAll("'", "'\\''")}'`; }
function sftpQuote(value) { return `"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`; }

function runProcess(command, arguments_, input = '') {
  return new Promise((resolve, reject) => {
    const child = spawn(command, arguments_, { stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '', diagnostic = '';
    child.stdout.setEncoding('utf8').on('data', chunk => { output += chunk; });
    child.stderr.setEncoding('utf8').on('data', chunk => { diagnostic += chunk; });
    child.on('error', reject);
    child.on('close', (code, signal) => code === 0 ? resolve(output) : reject(new Error(`${command} failed (${signal || code}): ${diagnostic.trim() || output.trim()}`)));
    child.stdin.on('error', () => {});
    child.stdin.end(input);
  });
}

const remoteGuards = String.raw`
set -eu
task_fail() { printf '%s\n' "$*" >&2; exit 1; }
taskRoot=$1
taskVersion=$2
taskStageName=$3
shift 3
taskReleases=$taskRoot/matrixcode/releases
taskFinal=$taskReleases/v$taskVersion
taskStage=$taskReleases/$taskStageName
for taskDirectory in "$taskRoot" "$taskRoot/matrixcode" "$taskReleases"; do
  [ ! -L "$taskDirectory" ] || task_fail "Refusing a symlinked release directory."
  if [ -e "$taskDirectory" ]; then
    [ -d "$taskDirectory" ] || task_fail "Release path is not a directory."
    [ "$(cd -P "$taskDirectory" && pwd -P)" = "$taskDirectory" ] || task_fail "Release directory resolves to another path."
  fi
done
[ -d "$taskRoot/matrixcode" ] || task_fail "The existing Matrix Code hosting directory is missing."
command -v sha256sum >/dev/null 2>&1 || task_fail "Remote sha256sum is required."
`;

const absentRelease = '[ ! -e "$taskFinal" ] && [ ! -L "$taskFinal" ] || task_fail "Release already exists; immutable releases cannot be overwritten."\n';
const inspectScript = remoteGuards + absentRelease + 'printf "Available release path: %s\\n" "$taskFinal"\n';
const stageScript = remoteGuards + absentRelease + String.raw`
umask 077
if [ ! -d "$taskReleases" ]; then mkdir -m 755 -- "$taskReleases"; fi
mkdir -m 700 -- "$taskStage"
`;
const publishScript = remoteGuards + absentRelease + String.raw`
[ -d "$taskStage" ] && [ ! -L "$taskStage" ] || task_fail "Release staging directory is missing or unsafe."
taskExpected=$(($# / 2))
taskCount=0
for taskEntry in "$taskStage"/* "$taskStage"/.[!.]* "$taskStage"/..?*; do
  if [ -e "$taskEntry" ] || [ -L "$taskEntry" ]; then taskCount=$((taskCount + 1)); fi
done
[ "$taskCount" -eq "$taskExpected" ] || task_fail "Unexpected files in the staging directory."
while [ "$#" -gt 0 ]; do
  taskFile=$taskStage/$1
  [ -f "$taskFile" ] && [ ! -L "$taskFile" ] || task_fail "Uploaded artifact is missing or is a symlink."
  taskHash=$(sha256sum < "$taskFile")
  taskHash=${'${taskHash%% *}'}
  [ "$taskHash" = "$2" ] || task_fail "Uploaded artifact checksum mismatch: $1"
  chmod 644 "$taskFile"
  shift 2
done
chmod 755 "$taskStage"
mv -T -n -- "$taskStage" "$taskFinal"
[ ! -e "$taskStage" ] && [ ! -L "$taskStage" ] || task_fail "Release appeared during upload; nothing was overwritten."
printf 'Published immutable release: %s\n' "$taskFinal"
`;
const cleanupScript = remoteGuards + String.raw`
if [ ! -e "$taskStage" ] && [ ! -L "$taskStage" ]; then exit 0; fi
[ -d "$taskStage" ] && [ ! -L "$taskStage" ] || task_fail "Unsafe staging directory; inspect it manually."
while [ "$#" -gt 0 ]; do
  taskFile=$taskStage/$1
  [ ! -L "$taskFile" ] || task_fail "Unsafe staged artifact; inspect it manually."
  if [ -f "$taskFile" ]; then rm -- "$taskFile"; fi
  shift 2
done
rmdir -- "$taskStage"
`;

export async function uploadRelease(plan, { run = runProcess, write = value => process.stdout.write(value) } = {}) {
  const stageName = `.upload-v${plan.version}-${randomUUID()}`;
  const remoteArguments = [plan.webRoot, plan.version, stageName, ...plan.files.flatMap(file => [file.filename, file.checksum])];
  const connection = ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2'];
  if (plan.identity) connection.push('-i', plan.identity, '-o', 'IdentitiesOnly=yes');
  const remote = script => run('ssh', ['-T', '-p', String(plan.port), ...connection, '-l', plan.user, '--', plan.host, `sh -s -- ${remoteArguments.map(shellQuote).join(' ')}`], script);
  write(`${plan.dryRun ? 'Dry run' : 'Release'}: v${plan.version}\n`);
  for (const file of plan.files) write(`  ${file.filename}: ${file.size} bytes, SHA-256 ${file.checksum}\n`);
  write(await remote(inspectScript));
  if (plan.dryRun) return;
  const snapshot = await mkdtemp(path.join(tmpdir(), 'matrixcode-release-upload-'));
  let stagingCreated = false;
  try {
    for (const file of plan.files) {
      await copyFile(file.localPath, path.join(snapshot, file.filename));
      if (await sha256(path.join(snapshot, file.filename)) !== file.checksum) throw new Error(`Artifact changed after validation: ${file.filename}.`);
    }
    await remote(stageScript);
    stagingCreated = true;
    const stagePath = path.posix.join(plan.webRoot, 'matrixcode/releases', stageName);
    const batch = plan.files.map(file => `put ${sftpQuote(path.join(snapshot, file.filename))} ${sftpQuote(path.posix.join(stagePath, file.filename))}`).join('\n') + '\n';
    await run('sftp', ['-q', '-b', '-', '-P', String(plan.port), ...connection, `${plan.user}@${plan.host}`], batch);
    write(await remote(publishScript));
    for (const file of plan.files) write(`${plan.origin}/matrixcode/releases/v${plan.version}/${encodeURIComponent(file.filename)}\n`);
  } catch (error) {
    if (stagingCreated) {
      try { await remote(cleanupScript); }
      catch { write(`Could not remove unpublished staging directory ${stageName}; inspect it manually.\n`); }
    }
    throw error;
  } finally {
    await rm(snapshot, { recursive: true, force: true });
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseOptions(process.argv.slice(2));
    if (options.help) process.stdout.write(help);
    else await uploadRelease(await prepareRelease(options));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
