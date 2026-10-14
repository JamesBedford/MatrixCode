# Release downloads

`upload.mjs` publishes verified artifacts to the existing Krystal account at
`https://julimbob.com/matrixcode/releases/v<VERSION>/`. It requires Node.js,
OpenSSH `ssh`/`sftp`, an authorized SSH key, and the verified server host key in
`~/.ssh/known_hosts`. The remote Linux host must provide `sha256sum` and GNU `mv`.
It preserves the browser app, homepage, other routes, and previous releases.

Put the release files in one directory. Select each artifact explicitly; accepted
extensions are `.dmg`, `.deb`, `.msi`, and `.zip`. Names must be plain ASCII
basenames without spaces. Optional `--manifest` adds `release.json`; `--notes`
adds `RELEASE_NOTES.md`. `SHA256SUMS.txt` is always included and must contain
exactly the selected files, excluding itself, using `sha256sum` format:

```text
<64 lowercase hex characters>  MatrixCode-1.1.0-macos.dmg
<64 lowercase hex characters>  MatrixCode-1.1.0-linux-amd64.deb
```

Generate the real checksums after signing/notarizing and packaging. Then run a
read-only dry run before publication:

```sh
node scripts/releases/upload.mjs --version 1.1.0 \
  --directory /private/tmp/matrixcode-release-artifacts \
  --artifact MatrixCode-1.1.0-macos.dmg \
  --artifact MatrixCode-1.1.0-linux-amd64.deb \
  --artifact MatrixCode-1.1.0-windows-x64.zip \
  --artifact MatrixCode-1.1.0-wallpaper-engine.zip \
  --dry-run
```

Use the same command without `--dry-run` to publish. The uploader snapshots the
validated files locally, uploads to a private sibling staging directory, checks
every remote SHA-256, and atomically renames the entire directory into place.
An existing release causes an error, including a release published concurrently.
Files in a published version are never replaced. Failed uploads remove only their
own known staging files; interruption can leave an unpublished staging directory.
If a connection fails after publication, inspect the final directory and its
checksums before retrying; a retry cannot overwrite it.

Connection defaults are `julimbob@kamino.krystal.uk:722`, document root
`/home/julimbob/public_html`, and public origin `https://julimbob.com`. Override
them with `--host`, `--user`, `--port`, `--web-root`, `--origin`, and `--identity`,
or the matching `MATRIXCODE_RELEASE_HOST`, `MATRIXCODE_RELEASE_USER`,
`MATRIXCODE_RELEASE_PORT`, `MATRIXCODE_RELEASE_WEB_ROOT`,
`MATRIXCODE_RELEASE_ORIGIN`, and `MATRIXCODE_RELEASE_IDENTITY` environment
variables. The destination is always `matrixcode/releases/v<VERSION>` below the
configured document root, and its existing `matrixcode` directory must be present.
Credentials are never stored by this script; password prompts and unverified host
keys are refused.

Run its isolated safety tests with:

```sh
node --test scripts/releases/upload.test.mjs
```
