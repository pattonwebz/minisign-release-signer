# Marketplace listing notes

## Recommended action title

`Minisign Release Signer`

## Short description

Sign release files with Minisign, verify signatures against your public key, and optionally log them to Sigstore Rekor.

## Longer summary

A GitHub Action for signing release artifacts with Minisign. It creates detached signatures, verifies them against your published public key before succeeding, and can record signatures in the Sigstore Rekor transparency log. Built for WordPress plugin and theme releases, but suitable for any distributable artifact.

## Key points to highlight

- Detached `.minisig` signatures written next to each artifact
- Trusted comments bind `slug` and `version` to prevent replay across releases
- Self-verification against your published public key before success
- Optional Sigstore Rekor transparency log upload
- Suitable for WordPress plugins and themes, but generic enough for any release files

## Repository name recommendation

Keep the repository name as `sign-release-action` for now.

Why:

- The Marketplace title users see is already `Minisign Release Signer`
- The current repository name is accurate and serviceable
- Renaming the repository would change the `uses:` path for consumers
- The current repo name only appears in the README usage example, so a rename is optional rather than necessary

If you rename before the first public release, `minisign-release-signer` is the cleanest tighter-alignment option. If you do that later, update the `uses:` examples in `README.md` and any published release notes.

