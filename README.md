# Minisign Release Signer

Sign WordPress plugin, theme, and other release artifacts with
[Minisign](https://jedisct1.github.io/minisign/) (Ed25519). The action creates
detached signatures, verifies them against your published public key before
succeeding, and can record each signature in the
[Sigstore Rekor](https://docs.sigstore.dev/logging/overview/) public
transparency log.

It is built for WordPress release workflows, but it is generic enough for any
distributable artifact such as ZIPs, tarballs, binaries, packages, and docs.

- **Detached signatures**: each input file gets a `<file>.minisig` next to
  it; the files themselves are untouched.
- **Replay protection**: every signature embeds a trusted comment
  (`slug:<slug> version:<version> signed:<utc>`) covered by minisign's global
  signature, so a valid signature for one project/version can't be replayed
  as another.
- **Self-verifying**: the action verifies its own output against the public
  key you distribute to users, and fails the job on any mismatch — a wrong
  key pair fails the release, not your users' installs.
- **Transparency logging**: signatures are recorded in Rekor
  (`--pki-format=minisign`), giving every release an independent,
  append-only timestamp. Log downtime warns rather than blocks by default.
- **Pinned tooling**: minisign and rekor-cli are downloaded from their
  official releases and checked against pinned sha256 hashes.

## Quick start

### WordPress plugin release example

```yaml
- name: Sign release
  id: sign
  uses: pattonwebz/minisign-release-signer@v1
  with:
    files: |
      dist/my-plugin-1.2.3.zip
    slug: my-plugin
    version: '1.2.3'
    secret-key: ${{ secrets.MINISIGN_SECRET_KEY }}
    secret-key-password: ${{ secrets.MINISIGN_SECRET_KEY_PASSWORD }}
    public-key: ${{ vars.MINISIGN_PUBLIC_KEY }}

- name: Upload artifacts
  uses: actions/upload-artifact@v4
  with:
    name: release
    path: |
      dist/*.zip
      dist/*.minisig
```

For WordPress projects, set `slug` to the plugin or theme slug users already
recognize from downloads, update checks, or release notes.

### The version is signed verbatim — match it to your verifier

`version` goes into the trusted comment exactly as passed (`v1.1.1` and
`1.1.1` are two different signed versions; both are accepted, allowed
characters are `A-Z a-z 0-9 . _ + -`). Verifiers compare it byte-for-byte,
so sign the same string your update pipeline reports. For WordPress flows
that means the plugin header / `new_version` style **without** a leading
`v` — if your tags carry one, strip it before passing:

```yaml
- name: Resolve version from tag
  id: meta
  run: echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
```

Mixing prefixed and bare versions across releases also confuses
`version_compare`-style downgrade checks (`v1.1.1` sorts *below* `1.1.0`),
so pick one form and keep it.

Multiple files are signed with the same slug/version trusted comment (one
release, several artifacts):

```yaml
    files: |
      dist/my-plugin-1.2.3.zip
      dist/my-plugin-docs-1.2.3.pdf
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `files` | yes | — | File(s) to sign, one path per line |
| `slug` | yes | — | Project slug, signed into every trusted comment |
| `version` | yes | — | Release version, signed into every trusted comment |
| `secret-key` | yes | — | Contents of the minisign secret key file (use a secret) |
| `secret-key-password` | no | `''` | Key password (separate secret); empty for unencrypted keys |
| `public-key` | yes | — | Public key to verify against (bare base64 or full `.pub` contents) |
| `rekor-upload` | no | `true` | Record signatures in the Rekor transparency log |
| `rekor-required` | no | `false` | Fail the job if a Rekor upload fails |
| `rekor-server` | no | `https://rekor.sigstore.dev` | Rekor server URL |
| `rekor-extra-args` | no | `''` | Extra flags for `rekor-cli upload`, split on whitespace (no quoting) |
| `minisign-version` / `minisign-sha256` | no | `0.12` / pinned | minisign release + tarball hash |
| `rekor-cli-version` / `rekor-cli-sha256` | no | `v1.5.3` / pinned | rekor-cli release + binary hash |

## Outputs

All outputs are newline-separated lists aligned with the `files` input order.

| Output | Description |
|---|---|
| `files` | The signed files |
| `signatures` | The generated `.minisig` paths |
| `rekor-indexes` | Rekor log index per file (`-` where upload skipped/failed) |
| `rekor-locations` | Rekor entry URL per file (`-` where upload skipped/failed) |

## Input safety

`slug` and `version` are signed verbatim into each signature's trusted
comment, so they are constrained to characters that cannot break the
`key:value` token grammar a verifier parses: `slug` must match
`[A-Za-z0-9._-]+` and `version` must match `[A-Za-z0-9._+-]+`. The action
fails fast on anything else. All inputs are passed to the internal script via
environment variables rather than interpolated into shell, so a value derived
from a release tag cannot inject shell commands.

## Key management

Generate a keypair with `minisign -G` and store the secret key file contents
and its password as two separate GitHub secrets. Publish the public key
(store page, repo, DNS TXT, Rekor) and pin it in whatever verifies your
releases. Verify a signed file anywhere with:

```sh
minisign -Vm my-plugin-1.2.3.zip -P 'RWS...your public key...'
```

## Verifying a Rekor entry

```sh
rekor-cli search --artifact my-plugin-1.2.3.zip
rekor-cli get --log-index <index>
```

## License

MIT
