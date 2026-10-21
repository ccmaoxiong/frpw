#!/usr/bin/env sh
# FRPW offline installer.
#
# Workflow:
#   1. Download the release binaries anywhere (browser, another machine).
#   2. Upload them to a directory on the target server together with
#      SHA256SUMS and this script (install-local.sh) plus install.sh.
#   3. Run:  sudo sh install-local.sh [server|node|agent]
#      (the server role additionally needs FRPW_LICENSE=FRPW-xxx...)
#
# No network access is needed on the target server. Server installs require a
# signed license key: the script verifies FRPW_LICENSE locally against the
# embedded Ed25519 public key before any file is touched. Agent and remote
# Node installs are license-free. Every binary is verified against
# SHA256SUMS before installation; any mismatch aborts the install.
set -eu

COMPONENT="${1:-${FRPW_COMPONENT:-server}}"
FRPW_VERSION="${FRPW_VERSION:-v1.0.2}"

# --- paid license gate (server role only) --------------------------------------
# Server installs require a signed license key (FRPW_LICENSE). Keys are issued
# by the vendor; the script embeds only the Ed25519 public key and verifies
# locally. Agent and remote Node installs are license-free.
FRPW_LICENSE="${FRPW_LICENSE:-${FRPW_LICENSE_KEY:-}}"
FRPW_LICENSE_PUBLIC_KEY="MrCLA8utGzPa5ysRO-0nVcxZ8Z7ZghS1J2SrdWTMwZI"

case "$FRPW_VERSION" in
    v*) ;;
    *) FRPW_VERSION="v$FRPW_VERSION" ;;
esac

log() {
    printf '%s\n' "==> $*"
}

die() {
    printf '%s\n' "error: $*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

sha256_file() {
    file="$1"
    if have sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        die "sha256sum or shasum is required"
    fi
}

checksum_for_asset() {
    asset_name="$1"
    sums="$2"
    awk -v name="$asset_name" '
        {
            checksum = $1
            file = $2
            sub(/\r$/, "", checksum)
            sub(/\r$/, "", file)
            sub(/^\*/, "", file)
            sub(/^\.\//, "", file)
            if (length(checksum) == 64 && file == name) {
                print tolower(checksum)
                exit
            }
        }
    ' "$sums"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) printf '%s' "amd64" ;;
        aarch64 | arm64) printf '%s' "arm64" ;;
        *) die "unsupported CPU architecture: $(uname -m)" ;;
    esac
}

# --- license verification (POSIX sh, needs base64 + openssl) -------------------

b64url_decode() {
    # stdin: unpadded base64url (may contain '~' grouping separators); stdout: binary
    tr -d "~ \t\r\n" | tr "_-" "/+" | awk '{
        mod = length($0) % 4
        if (mod == 2) printf "%s==", $0
        else if (mod == 3) printf "%s=", $0
        else if (mod == 0) printf "%s", $0
        else { printf "\ninvalid base64 length\n" > "/dev/stderr"; exit 1 }
    }' | base64 -d 2>/dev/null
}

hex_to_binary() {
    # portable hex -> binary; perl is available wherever openssl is
    perl -ne 'chomp; print pack("H*", $_)'
}

epoch_date() {
    # GNU date, BSD date, then the raw epoch as a last resort (busybox).
    date -d "@$1" +%Y-%m-%d 2>/dev/null || date -r "$1" +%Y-%m-%d 2>/dev/null || printf '%s' "$1"
}

verify_license() {
    [ -n "$FRPW_LICENSE" ] || die "this is a paid distribution: set FRPW_LICENSE to your license key, for example
  sudo FRPW_LICENSE=FRPW-xxx... sh install-local.sh server
Contact the vendor to purchase a license."
    have base64 || die "base64 is required to verify the license"
    have openssl || die "openssl is required to verify the license"
    have perl || die "perl is required to verify the license"

    key="$FRPW_LICENSE"
    case "$(printf '%s' "$key" | tr "a-z" "A-Z")" in
        FRPW-*) key="${key#?????}" ;;
    esac
    payload_b64="${key%%.*}"
    sig_b64="${key#*.}"
    [ "$payload_b64" != "$key" ] || die "invalid license key format"

    TMP_LIC="$(mktemp -d)"
    trap 'rm -rf "$TMP_LIC"' EXIT HUP INT TERM

    printf '%s' "$payload_b64" | b64url_decode > "$TMP_LIC/payload" \
        || die "license payload cannot be decoded"
    [ -s "$TMP_LIC/payload" ] || die "license payload cannot be decoded"
    printf '%s' "$sig_b64" | b64url_decode > "$TMP_LIC/sig" \
        || die "license signature cannot be decoded"
    [ "$(wc -c < "$TMP_LIC/sig" | tr -d " ")" = "64" ] || die "license signature has an invalid length"

    printf '%s' "$FRPW_LICENSE_PUBLIC_KEY" | b64url_decode | od -An -tx1 -v | tr -d " \n" > "$TMP_LIC/pub.hex"
    {
        printf '302a300506032b6570032100'
        cat "$TMP_LIC/pub.hex"
    } | hex_to_binary > "$TMP_LIC/pub.der"

    if ! openssl pkeyutl -verify -pubin -keyform DER \
            -inkey "$TMP_LIC/pub.der" -rawin \
            -in "$TMP_LIC/payload" -sigfile "$TMP_LIC/sig" >/dev/null 2>&1; then
        die "license signature verification failed (invalid or tampered key)"
    fi

    expires="$(cut -d"|" -f3 < "$TMP_LIC/payload")"
    case "$expires" in
        '' | *[!0-9]*) die "license expiry field is invalid" ;;
    esac
    now="$(date +%s)"
    [ "$now" -le "$expires" ] || die "license expired on $(date -d "@$expires" +%Y-%m-%d 2>/dev/null || date -r "$expires" +%Y-%m-%d 2>/dev/null || printf '%s' "$expires")"

    customer="$(cut -d"|" -f2 < "$TMP_LIC/payload")"
    plan="$(cut -d"|" -f5 < "$TMP_LIC/payload")"
    max_installs="$(cut -d"|" -f4 < "$TMP_LIC/payload")"
    key_version="$(cut -d"|" -f1 < "$TMP_LIC/payload")"
    expires_date="$(epoch_date "$expires")"
    days_left=$(( (expires - now + 86399) / 86400 ))
    max_display="${max_installs:-unlimited}"
    [ "$max_display" != "0" ] || max_display="unlimited"
    rm -rf "$TMP_LIC"
    trap - EXIT HUP INT TERM

    printf '%s\n' ""
    log "license verified - paid distribution"
    printf '    %-14s %s\n' "Key version:" "${key_version:-n/a}"
    printf '    %-14s %s\n' "Customer:" "${customer:-n/a}"
    printf '    %-14s %s\n' "Plan:" "${plan:-standard}"
    printf '    %-14s %s\n' "Valid until:" "$expires_date ($days_left days left)"
    printf '    %-14s %s\n' "Max installs:" "$max_display"
    printf '    %-14s %s\n' "Signature:" "Ed25519 verified"
    printf '%s\n' ""
}

# The release directory defaults to the directory containing this script so
# the common "upload everything into one folder" flow needs no variables.
SCRIPT_DIR=""
if [ -n "${0:-}" ] && [ -f "$0" ]; then
    SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)"
fi
RELEASE_DIR="${FRPW_RELEASE_DIR:-${SCRIPT_DIR:-$PWD}}"

[ "$(uname -s)" = "Linux" ] || die "install-local.sh supports Linux only"
case "$COMPONENT" in
    server) verify_license ;;
esac
[ -d "$RELEASE_DIR" ] || die "release directory not found: $RELEASE_DIR"
[ -f "$RELEASE_DIR/SHA256SUMS" ] || die "SHA256SUMS missing in $RELEASE_DIR (upload it together with the binaries)"
[ -f "$RELEASE_DIR/install.sh" ] || die "install.sh missing in $RELEASE_DIR (upload it together with this script)"

case "$COMPONENT" in
    server | node | agent) ;;
    *) die "component must be server, node, or agent" ;;
esac

ARCH="$(detect_arch)"
REQUIRED="frpw-$COMPONENT-$FRPW_VERSION-linux-$ARCH"

# Server mode also installs the managed client/node catalog when the files
# are present locally; warn instead of failing so minimal uploads still work.
OPTIONAL=""
if [ "$COMPONENT" = "server" ]; then
    OPTIONAL="frpw-client-$FRPW_VERSION-linux-amd64 frpw-client-$FRPW_VERSION-linux-arm64 frpw-client-$FRPW_VERSION-windows-amd64.exe frpw-client-$FRPW_VERSION-darwin-amd64 frpw-client-$FRPW_VERSION-darwin-arm64 frpw-node-$FRPW_VERSION-linux-amd64 frpw-node-$FRPW_VERSION-linux-arm64"
fi

log "verifying release files in $RELEASE_DIR"
[ -f "$RELEASE_DIR/$REQUIRED" ] || die "required binary missing: $RELEASE_DIR/$REQUIRED"

EXPECTED="$(checksum_for_asset "$REQUIRED" "$RELEASE_DIR/SHA256SUMS")"
[ -n "$EXPECTED" ] || die "SHA256SUMS has no entry for $REQUIRED"
ACTUAL="$(sha256_file "$RELEASE_DIR/$REQUIRED")"
[ "$ACTUAL" = "$EXPECTED" ] || die "checksum mismatch for $REQUIRED (file corrupted or tampered)"
log "verified $REQUIRED"

MISSING_OPTIONAL=""
for name in $OPTIONAL; do
    if [ -f "$RELEASE_DIR/$name" ]; then
        expected="$(checksum_for_asset "$name" "$RELEASE_DIR/SHA256SUMS")"
        actual="$(sha256_file "$RELEASE_DIR/$name")"
        [ -n "$expected" ] && [ "$actual" = "$expected" ] || die "checksum mismatch for $name"
    else
        MISSING_OPTIONAL="$MISSING_OPTIONAL $name"
    fi
done
if [ -n "$MISSING_OPTIONAL" ]; then
    printf '%s\n' "warning: optional catalog files not uploaded, managed client/node downloads will be limited:$MISSING_OPTIONAL" >&2
fi

log "installing FRPW $COMPONENT $FRPW_VERSION (offline mode)"
FRPW_LICENSE_INFO_SHOWN=1 FRPW_LICENSE="$FRPW_LICENSE" FRPW_LOCAL_DIR="$RELEASE_DIR" FRPW_VERSION="$FRPW_VERSION" sh "$RELEASE_DIR/install.sh" "$COMPONENT"
