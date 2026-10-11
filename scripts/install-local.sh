#!/usr/bin/env sh
# FRPW offline installer.
#
# Workflow:
#   1. Download the release binaries anywhere (browser, another machine).
#   2. Upload them to a directory on the target server together with
#      SHA256SUMS and this script (install-local.sh) plus install.sh.
#   3. Run:  sudo sh install-local.sh [server|node|agent]
#
# No network access is needed on the target server. Every binary is verified
# against SHA256SUMS before installation; any mismatch aborts the install.
set -eu

COMPONENT="${1:-${FRPW_COMPONENT:-server}}"
FRPW_VERSION="${FRPW_VERSION:-v1.0.0}"

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

# The release directory defaults to the directory containing this script so
# the common "upload everything into one folder" flow needs no variables.
SCRIPT_DIR=""
if [ -n "${0:-}" ] && [ -f "$0" ]; then
    SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)"
fi
RELEASE_DIR="${FRPW_RELEASE_DIR:-${SCRIPT_DIR:-$PWD}}"

[ "$(uname -s)" = "Linux" ] || die "install-local.sh supports Linux only"
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
FRPW_LOCAL_DIR="$RELEASE_DIR" FRPW_VERSION="$FRPW_VERSION" sh "$RELEASE_DIR/install.sh" "$COMPONENT"
