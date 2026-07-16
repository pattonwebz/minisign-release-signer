#!/usr/bin/env bash
#
# Sign one or more release files with minisign, verify each signature, and
# record them in the Sigstore Rekor transparency log.
#
# Usage:
#   sign-and-log.sh --slug my-plugin --version 1.2.3 -- <file> [<file> ...]
#
# The "--" before the file list is required: without it, a file named like a
# flag (e.g. "--changelog.txt") is parsed as an unknown option and rejected.
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
#   FILE_LABELS                   Optional per-file label, one per line, positionally
#                                 aligned with the file list (blank line = no label
#                                 for that file). Signed into that file's trusted
#                                 comment as label:<label>. Omit entirely for no
#                                 labels at all. A single trailing newline is
#                                 tolerated (e.g. from a YAML `|` block scalar) and
#                                 does not count as an extra blank entry; any other
#                                 line-count mismatch against the file list is an error.
#
# Outputs (written to $GITHUB_OUTPUT when set), newline-separated and aligned
# with the input file order: files, signatures, rekor-indexes, rekor-locations.
#
# The trusted comment binds the plugin slug and version — and, if given, a
# per-file label — into every signature (covered by minisign's global
# signature), preventing replay of a validly-signed file of another
# plugin/version/variant:
#   slug:<slug> version:<version>[ label:<label>] signed:<utc timestamp>
#
# The signed:<timestamp> is computed once and shared by every file in a run,
# so files signed together in the same invocation are identifiably part of
# one release moment even when their label differs.
set -euo pipefail

MINISIGN_BIN="${MINISIGN_BIN:-minisign}"
REKOR_BIN="${REKOR_BIN:-rekor-cli}"
REKOR_UPLOAD="${REKOR_UPLOAD:-true}"
REKOR_REQUIRED="${REKOR_REQUIRED:-false}"
REKOR_SERVER="${REKOR_SERVER:-https://rekor.sigstore.dev}"

# Booleans are compared with exact string equality below, so a
# non-canonical spelling (e.g. "True", "1", "yes") would otherwise silently
# behave like "false" with no diagnostic — most dangerous for
# REKOR_REQUIRED, where a user expecting a hard release gate would instead
# get silent warn-and-continue.
for _var in REKOR_UPLOAD REKOR_REQUIRED; do
    _val="${!_var}"
    [[ "$_val" == "true" || "$_val" == "false" ]] || {
        echo "Invalid ${_var} '${_val}': must be exactly 'true' or 'false'" >&2
        exit 2
    }
done
unset _var _val

if [[ "$REKOR_REQUIRED" == "true" && "$REKOR_UPLOAD" != "true" ]]; then
    echo "::warning::rekor-required is true but rekor-upload is false; rekor-required has no effect since no upload is attempted."
fi
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

# FILE_LABELS is positionally aligned with FILES, so blank lines are
# meaningful (they mean "no label") and must be preserved rather than
# filtered like INPUT_FILES's blank lines are. A single trailing newline is
# stripped first because a YAML `|` block scalar always ends in exactly one
# "\n" that isn't part of the user's data — without stripping it, a
# herestring split would read it as one extra trailing blank entry and
# every run with a plain trailing newline (the common case) would fail the
# line-count check below.
FILE_LABELS="${FILE_LABELS:-}"
FILE_LABELS="${FILE_LABELS%$'\n'}"
FILE_LABELS="${FILE_LABELS%$'\r'}"
LABELS=()
if [[ -n "$FILE_LABELS" ]]; then
    while IFS= read -r line; do
        # Strip a trailing CR so a CRLF-edited workflow file's multiline
        # `file-labels:` block doesn't leave "label\r" entries (blank
        # lines are meaningful here, so this must run before anything
        # else touches $line).
        line="${line%$'\r'}"
        LABELS+=( "$line" )
    done <<< "$FILE_LABELS"
    [[ ${#LABELS[@]} -eq ${#FILES[@]} ]] || {
        echo "file-labels has ${#LABELS[@]} line(s), expected ${#FILES[@]} (one per file in 'files', blank = no label)" >&2
        exit 2
    }
    for i in "${!LABELS[@]}"; do
        label="${LABELS[$i]}"
        [[ -z "$label" || "$label" =~ ^[A-Za-z0-9._-]+$ ]] || {
            echo "Invalid label '${label}' for file '${FILES[$i]}': allowed characters are A-Z a-z 0-9 . _ -" >&2
            exit 2
        }
    done
fi

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
#
# Trailing newlines (and any stray CR from a Windows-edited secret) are
# stripped before checking for embedded newlines: a bare base64 key with
# one accidental trailing "\n" or "\r\n" (e.g. from `gh variable set NAME
# < file`) must still be classified as "bare", or the required "untrusted
# comment:" header line never gets written and minisign fails to parse the
# resulting file.
MINISIGN_PUBLIC_KEY_TRIMMED="$MINISIGN_PUBLIC_KEY"
while [[ "$MINISIGN_PUBLIC_KEY_TRIMMED" == *$'\n' || "$MINISIGN_PUBLIC_KEY_TRIMMED" == *$'\r' ]]; do
    MINISIGN_PUBLIC_KEY_TRIMMED="${MINISIGN_PUBLIC_KEY_TRIMMED%$'\n'}"
    MINISIGN_PUBLIC_KEY_TRIMMED="${MINISIGN_PUBLIC_KEY_TRIMMED%$'\r'}"
done

PUBKEY_FILE="$WORK/minisign.pub"
if [[ "$MINISIGN_PUBLIC_KEY_TRIMMED" == *$'\n'* || "$MINISIGN_PUBLIC_KEY_TRIMMED" == untrusted* ]]; then
    printf '%s\n' "$MINISIGN_PUBLIC_KEY_TRIMMED" > "$PUBKEY_FILE"
else
    printf 'untrusted comment: minisign public key\n%s\n' "$MINISIGN_PUBLIC_KEY_TRIMMED" > "$PUBKEY_FILE"
fi

# Shared by every file in this run (see the header comment for why).
SIGNED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

SIGNATURES=()
REKOR_INDEXES=()
REKOR_LOCATIONS=()

sign_one() {
    local file="$1" label="$2"
    local sig="${file}.minisig"
    local trusted_comment="slug:${SLUG} version:${VERSION}"
    [[ -n "$label" ]] && trusted_comment+=" label:${label}"
    trusted_comment+=" signed:${SIGNED_AT}"

    echo "Signing ${file} (${trusted_comment})"

    if [[ -n "${MINISIGN_SECRET_KEY_PASSWORD:-}" ]]; then
        printf '%s\n' "$MINISIGN_SECRET_KEY_PASSWORD" | "$MINISIGN_BIN" -S \
            -s "$SECKEY" -m "$file" -x "$sig" \
            -t "$trusted_comment" -c "signature for ${SLUG} ${VERSION}"
    else
        "$MINISIGN_BIN" -S \
            -s "$SECKEY" -m "$file" -x "$sig" \
            -t "$trusted_comment" -c "signature for ${SLUG} ${VERSION}" < /dev/null
    fi

    # Belt and braces: verify what was just produced against the *public* key
    # customers will pin. Catches wrong-key mixups and format drift immediately.
    local verify_out
    verify_out="$("$MINISIGN_BIN" -Vm "$file" -x "$sig" -p "$PUBKEY_FILE")"
    echo "$verify_out"

    if ! grep -qF "Trusted comment: ${trusted_comment}" <<< "$verify_out"; then
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
    # success, not failure. As of rekor-cli v1.5.3 this case actually exits
    # 0 (with an "Entry already exists" message), so the "already exists"
    # check below never has to override a nonzero status in practice — it's
    # kept as a defensive fallback in case a future/older rekor-cli treats a
    # duplicate entry as an error instead.
    if [[ $rekor_status -ne 0 && "$rekor_out" != *"already exists"* ]]; then
        if [[ "$REKOR_REQUIRED" == "true" ]]; then
            echo "Rekor upload failed for ${file} and REKOR_REQUIRED=true." >&2
            exit 1
        fi
        echo "::warning::Rekor upload failed for ${file}; continuing because REKOR_REQUIRED=false."
    else
        index="$(grep -oiE 'index:? [0-9]+' <<< "$rekor_out" | grep -oE '[0-9]+' | head -1 || true)"
        location="$(grep -oE 'https?://[^ ]+/api/v1/log/entries/[0-9a-f]+' <<< "$rekor_out" | head -1 || true)"

        # rekor-cli's "already exists" upload response carries a Location
        # but omits the Index (it's a real field on the entry, just not
        # printed for that case). Look it up by UUID so a re-run of an
        # already-logged file still reports its index instead of "-".
        if [[ -z "$index" && -n "$location" ]]; then
            local uuid get_out
            uuid="${location##*/}"
            get_out="$("$REKOR_BIN" get --uuid "$uuid" --rekor_server "$REKOR_SERVER" 2>&1 || true)"
            index="$(grep -oiE 'index:? [0-9]+' <<< "$get_out" | grep -oE '[0-9]+' | head -1 || true)"
        fi
    fi

    # "-" placeholder for "no entry": an empty string can't round-trip as a
    # distinct output line (blank lines collapse), so a sentinel keeps the
    # lists genuinely 1:1 with FILES and countable by consumers.
    REKOR_INDEXES+=( "${index:--}" )
    REKOR_LOCATIONS+=( "${location:--}" )
}

for i in "${!FILES[@]}"; do
    f="${FILES[$i]}"
    sign_one "$f" "${LABELS[$i]:-}"
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
