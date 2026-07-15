#!/usr/bin/env bash
#
# Sign one or more release files with minisign, verify each signature, and
# record them in the Sigstore Rekor transparency log.
#
# Usage:
#   sign-and-log.sh --slug my-plugin --version 1.2.3 <file> [<file> ...]
#
# Each <file> gets a detached signature written next to it as <file>.minisig.
# The files themselves are not modified.
#
# Environment:
#   MINISIGN_SECRET_KEY           Contents of the minisign secret key file. Required.
#   MINISIGN_SECRET_KEY_PASSWORD  Password for the key. Omit for unencrypted (-W) keys.
#   MINISIGN_PUBLIC_KEY           Matching public key: bare base64 line or full
#                                 minisign.pub contents. Required — every signature
#                                 is verified against it before this script succeeds.
#   MINISIGN_BIN                  minisign binary. Default: minisign.
#   REKOR_UPLOAD                  "true" to record each signature in Rekor. Default: true.
#   REKOR_REQUIRED                "true" to fail the release if a Rekor upload fails.
#                                 Default: false (warn and continue — Rekor being down
#                                 should not brick a release).
#   REKOR_BIN                     rekor-cli binary. Default: rekor-cli.
#   REKOR_SERVER                  Rekor server URL. Default: https://rekor.sigstore.dev.
#   REKOR_EXTRA_ARGS              Extra flags appended to every `rekor-cli upload`
#                                 call, split on whitespace (no quoting/escaping) —
#                                 for any additional naming/identifier flags Rekor
#                                 needs now or grows later.
#
# Outputs (written to $GITHUB_OUTPUT when set), newline-separated and aligned
# with the input file order: files, signatures, rekor-indexes, rekor-locations.
#
# The trusted comment binds the plugin slug and version into every signature
# (covered by minisign's global signature), preventing replay of a
# validly-signed file of another plugin or an older version:
#   slug:<slug> version:<version> signed:<utc timestamp>
set -euo pipefail

MINISIGN_BIN="${MINISIGN_BIN:-minisign}"
REKOR_BIN="${REKOR_BIN:-rekor-cli}"
REKOR_UPLOAD="${REKOR_UPLOAD:-true}"
REKOR_REQUIRED="${REKOR_REQUIRED:-false}"
REKOR_SERVER="${REKOR_SERVER:-https://rekor.sigstore.dev}"
REKOR_EXTRA=()
if [[ -n "${REKOR_EXTRA_ARGS:-}" ]]; then
    read -ra REKOR_EXTRA <<< "$REKOR_EXTRA_ARGS"
fi
SLUG="" VERSION=""
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slug)    SLUG="$2";    shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --)        shift; FILES+=( "$@" ); break ;;
        --*) echo "Unknown option: $1" >&2; exit 2 ;;
        *)  FILES+=( "$1" ); shift ;;
    esac
done

[[ -n "$SLUG" && -n "$VERSION" ]] || { echo "Required: --slug and --version" >&2; exit 2; }

# The slug and version are signed verbatim into the trusted comment, which
# downstream verifiers parse as whitespace-separated key:value tokens. A slug
# or version containing whitespace or a colon could inject a second slug:/
# version: token into the signed comment and change what a verifier reads.
# Constrain both to characters that cannot break the token grammar.
[[ "$SLUG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid --slug '${SLUG}': allowed characters are A-Z a-z 0-9 . _ -" >&2; exit 2; }
[[ "$VERSION" =~ ^[A-Za-z0-9._+-]+$ ]] || { echo "Invalid --version '${VERSION}': allowed characters are A-Z a-z 0-9 . _ + -" >&2; exit 2; }

[[ ${#FILES[@]} -gt 0 ]] || { echo "At least one file to sign is required" >&2; exit 2; }
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "File not found: $f" >&2; exit 2; }
    # A newline in a path would corrupt the newline-delimited step outputs.
    [[ "$f" != *$'\n'* ]] || { echo "File path contains a newline, which is not supported: $f" >&2; exit 2; }
done
[[ -n "${MINISIGN_SECRET_KEY:-}" ]] || { echo "MINISIGN_SECRET_KEY is not set" >&2; exit 2; }
[[ -n "${MINISIGN_PUBLIC_KEY:-}" ]] || { echo "MINISIGN_PUBLIC_KEY is not set" >&2; exit 2; }
command -v "$MINISIGN_BIN" >/dev/null || { echo "minisign binary not found: $MINISIGN_BIN" >&2; exit 2; }
if [[ "$REKOR_UPLOAD" == "true" ]]; then
    command -v "$REKOR_BIN" >/dev/null || { echo "rekor-cli binary not found: $REKOR_BIN" >&2; exit 2; }
fi

WORK="$(mktemp -d)"
chmod 700 "$WORK"
# Cover signal-based termination too (job cancellation on self-hosted /
# persistent runners), not just a clean EXIT, so the decrypted key file is
# never left behind.
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

SECKEY="$WORK/minisign.key"
touch "$SECKEY" && chmod 600 "$SECKEY"
printf '%s\n' "$MINISIGN_SECRET_KEY" > "$SECKEY"

# Normalise the public key to a real .pub file: both minisign -p and
# rekor-cli's minisign PKI parser want the two-line file form.
PUBKEY_FILE="$WORK/minisign.pub"
if [[ "$MINISIGN_PUBLIC_KEY" == *$'\n'* || "$MINISIGN_PUBLIC_KEY" == untrusted* ]]; then
    printf '%s\n' "$MINISIGN_PUBLIC_KEY" > "$PUBKEY_FILE"
else
    printf 'untrusted comment: minisign public key\n%s\n' "$MINISIGN_PUBLIC_KEY" > "$PUBKEY_FILE"
fi

TRUSTED_COMMENT="slug:${SLUG} version:${VERSION} signed:$(date -u +%Y-%m-%dT%H:%M:%SZ)"

SIGNATURES=()
REKOR_INDEXES=()
REKOR_LOCATIONS=()

sign_one() {
    local file="$1"
    local sig="${file}.minisig"

    echo "Signing ${file} (${TRUSTED_COMMENT})"

    if [[ -n "${MINISIGN_SECRET_KEY_PASSWORD:-}" ]]; then
        printf '%s\n' "$MINISIGN_SECRET_KEY_PASSWORD" | "$MINISIGN_BIN" -S \
            -s "$SECKEY" -m "$file" -x "$sig" \
            -t "$TRUSTED_COMMENT" -c "signature for ${SLUG} ${VERSION}"
    else
        "$MINISIGN_BIN" -S \
            -s "$SECKEY" -m "$file" -x "$sig" \
            -t "$TRUSTED_COMMENT" -c "signature for ${SLUG} ${VERSION}" < /dev/null
    fi

    # Belt and braces: verify what was just produced against the *public* key
    # customers will pin. Catches wrong-key mixups and format drift immediately.
    local verify_out
    verify_out="$("$MINISIGN_BIN" -Vm "$file" -x "$sig" -p "$PUBKEY_FILE")"
    echo "$verify_out"

    if ! grep -qF "Trusted comment: ${TRUSTED_COMMENT}" <<< "$verify_out"; then
        echo "Post-sign verification of ${file} did not return the expected trusted comment." >&2
        exit 1
    fi

    echo "Signed and verified: ${sig}"
    SIGNATURES+=( "$sig" )
}

rekor_one() {
    local file="$1"
    local sig="${file}.minisig"
    local rekor_out rekor_status index="" location=""

    echo "Recording ${sig} in Rekor (${REKOR_SERVER})"

    set +e
    rekor_out="$("$REKOR_BIN" upload \
        --rekor_server "$REKOR_SERVER" \
        --artifact "$file" \
        --signature "$sig" \
        --pki-format minisign \
        --public-key "$PUBKEY_FILE" \
        ${REKOR_EXTRA[@]+"${REKOR_EXTRA[@]}"} 2>&1)"
    rekor_status=$?
    set -e

    echo "$rekor_out"

    # An identical entry from a re-run job already being in the log is
    # success, not failure.
    if [[ $rekor_status -ne 0 && "$rekor_out" != *"already exists"* ]]; then
        if [[ "$REKOR_REQUIRED" == "true" ]]; then
            echo "Rekor upload failed for ${file} and REKOR_REQUIRED=true." >&2
            exit 1
        fi
        echo "::warning::Rekor upload failed for ${file}; continuing because REKOR_REQUIRED=false."
    else
        index="$(grep -oE 'index [0-9]+' <<< "$rekor_out" | grep -oE '[0-9]+' | head -1 || true)"
        location="$(grep -oE 'https?://[^ ]+/api/v1/log/entries/[0-9a-f]+' <<< "$rekor_out" | head -1 || true)"
    fi

    # "-" placeholder for "no entry": an empty string can't round-trip as a
    # distinct output line (blank lines collapse), so a sentinel keeps the
    # lists genuinely 1:1 with FILES and countable by consumers.
    REKOR_INDEXES+=( "${index:--}" )
    REKOR_LOCATIONS+=( "${location:--}" )
}

for f in "${FILES[@]}"; do
    sign_one "$f"
    if [[ "$REKOR_UPLOAD" == "true" ]]; then
        rekor_one "$f"
    else
        # Rekor skipped: still emit a placeholder row per file so every
        # output list stays aligned 1:1 with FILES.
        REKOR_INDEXES+=( "-" )
        REKOR_LOCATIONS+=( "-" )
    fi
done

emit_output() {
    # A random delimiter can't be forged by a file path, so a file literally
    # named like the delimiter cannot terminate the heredoc early.
    local name="$1"; shift
    local delim="ghadelim_${RANDOM}${RANDOM}_EOF"
    {
        echo "${name}<<${delim}"
        [[ $# -gt 0 ]] && printf '%s\n' "$@"
        echo "${delim}"
    } >> "$GITHUB_OUTPUT"
}

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    emit_output files           "${FILES[@]}"
    emit_output signatures      "${SIGNATURES[@]}"
    emit_output rekor-indexes   "${REKOR_INDEXES[@]}"
    emit_output rekor-locations "${REKOR_LOCATIONS[@]}"
fi

echo "Done: signed ${#FILES[@]} file(s) as ${SLUG} ${VERSION}."
