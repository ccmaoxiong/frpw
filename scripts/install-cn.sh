#!/usr/bin/env sh
set -eu

FRPW_VERSION="v1.0.0"
FRPW_REPO="ccmaoxiong/frpw"
FRPW_RELEASE_URL="https://github.com/$FRPW_REPO/releases/download/$FRPW_VERSION"
EXPECTED_INSTALL_SHA256="776983dd4594bd68ed373c56b2e8de1b7fb5b3abec412fa65b7c6ec1ddc98972"
EXPECTED_SUMS_SHA256="b3e3ba97308fdda38b1b1c67aa6539d3872493097d6efd647911bcec96e02b03"
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
        printf '%s\n' "${FRPW_CN_MIRROR_BASE_URL%/}"
        return
    fi
    printf '%s\n' \
        "https://ghfast.top/$FRPW_RELEASE_URL" \
        "https://gh-proxy.com/$FRPW_RELEASE_URL" \
        "https://ghproxy.net/$FRPW_RELEASE_URL" \
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
