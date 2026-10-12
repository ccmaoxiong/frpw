#!/usr/bin/env sh
set -eu

COMPONENT="${1:-${FRPW_COMPONENT:-server}}"
FRPW_VERSION="v1.0.1"
FRPW_REPO="ccmaoxiong/frpw"
FRPW_RELEASE_URL="https://github.com/$FRPW_REPO/releases/download/$FRPW_VERSION"

# --- paid license gate ---------------------------------------------------------
FRPW_LICENSE="${FRPW_LICENSE:-${FRPW_LICENSE_KEY:-}}"
FRPW_LICENSE_PUBLIC_KEY="MrCLA8utGzPa5ysRO-0nVcxZ8Z7ZghS1J2SrdWTMwZI"
EXPECTED_INSTALL_SHA256="4ae1fc13ca1caf23b187c1e078ebe816cd22e1926d15fcf165beebd85522216a"
EXPECTED_SUMS_SHA256="9c7bcfaef03b6cc21595df3a50ac954763d2c31d44b02f7714c977ff3f8d9984"
FRPW_CONNECT_TIMEOUT="${FRPW_CONNECT_TIMEOUT:-15}"
FRPW_MAX_TIME="${FRPW_MAX_TIME:-300}"
FRPW_RETRIES="${FRPW_RETRIES:-5}"
TMP_DIR=""

log() {
    printf '%s\n' "==> $*"
}

warn() {
    printf '%s\n' "warning: $*" >&2
}

die() {
    printf '%s\n' "error: $*" >&2
    exit 1
}

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

trap 'cleanup' EXIT HUP INT TERM

have() {
    command -v "$1" >/dev/null 2>&1
}

validate_url() {
    url="$1"
    case "$url" in
        http://* | https://*) ;;
        *) die "invalid mirror URL: $url" ;;
    esac
    case "$url" in
        *[[:space:]]*) die "mirror URL contains whitespace or control characters" ;;
    esac
}

download_file() {
    url="$1"
    destination="$2"
    temporary="$destination.part"
    validate_url "$url"
    rm -f "$destination" "$temporary"
    if have curl; then
        if curl --http1.1 -fsSL --location --retry "$FRPW_RETRIES" --retry-delay 2 \
            --connect-timeout "$FRPW_CONNECT_TIMEOUT" --max-time "$FRPW_MAX_TIME" \
            -H "User-Agent: frpw-cn-installer" \
            -o "$temporary" "$url"; then
            :
        else
            rm -f "$temporary"
            return 1
        fi
    elif have wget; then
        if wget -qO "$temporary" --tries="$FRPW_RETRIES" --timeout="$FRPW_CONNECT_TIMEOUT" \
            --header="User-Agent: frpw-cn-installer" "$url"; then
            :
        else
            rm -f "$temporary"
            return 1
        fi
    else
        die "curl or wget is required"
    fi
    if [ -s "$temporary" ]; then
        mv -f "$temporary" "$destination"
        return 0
    fi
    rm -f "$temporary"
    return 1
}

# --- license verification (same Ed25519 scheme as install.sh) ------------------

b64url_decode() {
    tr -d "~ \t\r\n" | tr "_-" "/+" | awk '{
        mod = length($0) % 4
        if (mod == 2) printf "%s==", $0
        else if (mod == 3) printf "%s=", $0
        else if (mod == 0) printf "%s", $0
        else { printf "\ninvalid base64 length\n" > "/dev/stderr"; exit 1 }
    }' | base64 -d 2>/dev/null
}

hex_to_binary() {
    perl -ne 'chomp; print pack("H*", $_)'
}

verify_license() {
    [ -n "$FRPW_LICENSE" ] || die "this is a paid distribution: set FRPW_LICENSE to your license key, for example
  curl -fsSL <install-cn.sh URL> | sudo FRPW_LICENSE=FRPW-xxx... sh -s -- server
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
    printf '%s' "$payload_b64" | b64url_decode > "$TMP_LIC/payload" \
        || { rm -rf "$TMP_LIC"; die "license payload cannot be decoded"; }
    [ -s "$TMP_LIC/payload" ] || { rm -rf "$TMP_LIC"; die "license payload cannot be decoded"; }
    printf '%s' "$sig_b64" | b64url_decode > "$TMP_LIC/sig" \
        || { rm -rf "$TMP_LIC"; die "license signature cannot be decoded"; }
    [ "$(wc -c < "$TMP_LIC/sig" | tr -d " ")" = "64" ] || { rm -rf "$TMP_LIC"; die "license signature has an invalid length"; }

    printf '%s' "$FRPW_LICENSE_PUBLIC_KEY" | b64url_decode | od -An -tx1 -v | tr -d " \n" > "$TMP_LIC/pub.hex"
    {
        printf '302a300506032b6570032100'
        cat "$TMP_LIC/pub.hex"
    } | hex_to_binary > "$TMP_LIC/pub.der"

    if ! openssl pkeyutl -verify -pubin -keyform DER \
            -inkey "$TMP_LIC/pub.der" -rawin \
            -in "$TMP_LIC/payload" -sigfile "$TMP_LIC/sig" >/dev/null 2>&1; then
        rm -rf "$TMP_LIC"
        die "license signature verification failed (invalid or tampered key)"
    fi

    expires="$(cut -d"|" -f3 < "$TMP_LIC/payload")"
    case "$expires" in
        '' | *[!0-9]*) rm -rf "$TMP_LIC"; die "license expiry field is invalid" ;;
    esac
    now="$(date +%s)"
    [ "$now" -le "$expires" ] || { rm -rf "$TMP_LIC"; die "license expired"; }

    customer="$(cut -d"|" -f2 < "$TMP_LIC/payload")"
    rm -rf "$TMP_LIC"
    log "license verified: $customer"
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

verify_sha256() {
    file="$1"
    expected="$2"
    actual="$(sha256_file "$file")"
    [ "$actual" = "$expected" ]
}

mirror_bases() {
    if [ -n "${FRPW_CN_MIRROR_BASE_URL:-}" ]; then
        # Accept one or more space-separated bases; each is tried in order.
        for base in $FRPW_CN_MIRROR_BASE_URL; do
            printf '%s\n' "${base%/}"
        done
        return
    fi
    printf '%s\n' \
        "https://ghfast.top/$FRPW_RELEASE_URL" \
        "https://gh-proxy.com/$FRPW_RELEASE_URL" \
        "https://ghproxy.net/$FRPW_RELEASE_URL" \
        "https://gh.acmsz.top/$FRPW_RELEASE_URL" \
        "$FRPW_RELEASE_URL"
}

prepare_mirror() {
    base="$1"
    sums="$2"
    installer="$3"
    if ! download_file "$base/SHA256SUMS" "$sums"; then
        return 1
    fi
    if ! verify_sha256 "$sums" "$EXPECTED_SUMS_SHA256"; then
        warn "mirror checksum manifest verification failed: $base"
        return 1
    fi
    if ! download_file "$base/install.sh" "$installer"; then
        return 1
    fi
    if ! verify_sha256 "$installer" "$EXPECTED_INSTALL_SHA256"; then
        warn "mirror installer verification failed: $base"
        return 1
    fi
    return 0
}

main() {
    TMP_DIR="$(mktemp -d)"
    case "$COMPONENT" in
        server) verify_license ;;
    esac
    sums="$TMP_DIR/SHA256SUMS"
    installer="$TMP_DIR/install.sh"
    for base in $(mirror_bases); do
        base="${base%/}"
        log "trying China mirror: $base"
        if prepare_mirror "$base" "$sums" "$installer"; then
            log "using verified mirror: $base"
            FRPW_DOWNLOAD_BASE_URL="$base" \
                FRPW_USE_GITHUB_API=0 \
                FRPW_VERSION="$FRPW_VERSION" \
                sh "$installer" "$@"
            exit $?
        fi
        warn "mirror unavailable or unverified: $base"
    done
    die "all China mirrors failed; use the standard installer or set FRPW_CN_MIRROR_BASE_URL"
}

main "$@"
