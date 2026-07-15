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

Rename the repository to `minisign-release-signer`.

Why:

- It aligns the repository path with the Marketplace title users will see
- It makes the `uses:` path more descriptive and memorable
- This project has not been publicly released yet, so the migration cost is low
- The new name is available and avoids confusion with other Marketplace listings

After the rename, use `pattonwebz/minisign-release-signer@v1` in workflow examples and release notes.


