#!/usr/bin/env sh
set -eu

COMPONENT="${1:-${FRPW_COMPONENT:-server}}"
FRPW_VERSION="v1.0.2"
FRPW_REPO="ccmaoxiong/frpw"
FRPW_RELEASE_URL="https://github.com/$FRPW_REPO/releases/download/$FRPW_VERSION"

# --- paid license gate ---------------------------------------------------------
FRPW_LICENSE="${FRPW_LICENSE:-${FRPW_LICENSE_KEY:-}}"
FRPW_LICENSE_PUBLIC_KEY="MrCLA8utGzPa5ysRO-0nVcxZ8Z7ZghS1J2SrdWTMwZI"
EXPECTED_INSTALL_SHA256="8edea61087c65ee3adbbaa02d0ddb4055bef985bb8f99a4c3fb812ff6500aaa4"
EXPECTED_SUMS_SHA256="949dac2c351decb8ca58652ce519dd199f72ca282a3ae63a4f4290c70a0a0a4f"
FRPW_CONNECT_TIMEOUT="${FRPW_CONNECT_TIMEOUT:-15}"
FRPW_MAX_TIME="${FRPW_MAX_TIME:-300}"
FRPW_RETRIES="${FRPW_RETRIES:-5}"
FRPW_NO_PROGRESS="${FRPW_NO_PROGRESS:-0}"
TMP_DIR=""

log() {
    printf '%s\n' "==> $*"
}

warn() {
    printf '%s\n' "警告: $*" >&2
}

die() {
    printf '%s\n' "错误: $*" >&2
    exit 1
}

human_size() {
    bytes="$1"
    case "$bytes" in
        '' | *[!0-9]*) printf '%s' "$bytes"; return 0 ;;
    esac
    awk -v n="$bytes" 'BEGIN {
        if (n < 1048576) { printf "%d 字节", n; exit }
        split("MB GB TB", unit, " ")
        n /= 1048576
        i = 1
        while (n >= 1024 && i < 3) { n /= 1024; i++ }
        printf "%.1f %s", n, unit[i]
    }'
}

file_size() {
    wc -c < "$1" | tr -d ' '
}

mask_license() {
    key="${1:-}"
    case "$(printf '%s' "$key" | tr 'a-z' 'A-Z')" in
        FRPW-*) key="${key#?????}" ;;
    esac
    suffix="$(printf '%s' "$key" | tr -cd 'A-Za-z0-9' | tail -c 4)"
    printf 'FRPW-****%s' "$suffix"
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

mirror_origin() {
    printf '%s' "$1" | awk -F/ '{print $1 "//" $3}'
}

validate_url() {
    url="$1"
    case "$url" in
        http://* | https://*) ;;
        *) die "无效的镜像地址: $url" ;;
    esac
    case "$url" in
        *[[:space:]]*) die "镜像地址包含空白或控制字符" ;;
    esac
}

download_file() {
    url="$1"
    destination="$2"
    mode="${3:-}"
    temporary="$destination.part"
    validate_url "$url"
    rm -f "$destination" "$temporary"
    curl_flags="-fsSL"
    wget_flags="-q"
    if [ "$mode" = "progress" ] && [ "$FRPW_NO_PROGRESS" != "1" ] && [ -t 2 ]; then
        curl_flags="-fSL --progress-bar"
        wget_flags=""
    fi
    if have curl; then
        if curl --http1.1 $curl_flags --location --retry "$FRPW_RETRIES" --retry-delay 2 \
            --connect-timeout "$FRPW_CONNECT_TIMEOUT" --max-time "$FRPW_MAX_TIME" \
            -H "User-Agent: frpw-cn-installer" \
            -o "$temporary" "$url"; then
            :
        else
            rm -f "$temporary"
            return 1
        fi
    elif have wget; then
        if wget $wget_flags -O "$temporary" --tries="$FRPW_RETRIES" --timeout="$FRPW_CONNECT_TIMEOUT" \
            --header="User-Agent: frpw-cn-installer" "$url"; then
            :
        else
            rm -f "$temporary"
            return 1
        fi
    else
        die "需要 curl 或 wget"
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
        else { printf "\nBase64 数据长度无效\n" > "/dev/stderr"; exit 1 }
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

verify_license() (
    [ -n "$FRPW_LICENSE" ] || die "此发行版为付费授权：请设置 FRPW_LICENSE 授权密钥，例如
  curl -fsSL <install-cn.sh 地址> | sudo FRPW_LICENSE=FRPW-xxx... sh -s -- server
请联系供应商购买授权。"
    have base64 || die "未找到 base64，无法校验授权"
    have openssl || die "未找到 openssl，无法校验授权"
    have perl || die "未找到 perl，无法校验授权"

    key="$FRPW_LICENSE"
    case "$(printf '%s' "$key" | tr "a-z" "A-Z")" in
        FRPW-*) key="${key#?????}" ;;
    esac
    payload_b64="${key%%.*}"
    sig_b64="${key#*.}"
    [ "$payload_b64" != "$key" ] || die "授权密钥格式无效"

    TMP_LIC="$(mktemp -d)"
    trap 'rm -rf "$TMP_LIC"' EXIT HUP INT TERM

    printf '%s' "$payload_b64" | b64url_decode > "$TMP_LIC/payload" \
        || die "授权数据无法解码"
    [ -s "$TMP_LIC/payload" ] || die "授权数据无法解码"
    printf '%s' "$sig_b64" | b64url_decode > "$TMP_LIC/sig" \
        || die "授权签名无法解码"
    [ "$(wc -c < "$TMP_LIC/sig" | tr -d " ")" = "64" ] || die "授权签名长度无效"

    printf '%s' "$FRPW_LICENSE_PUBLIC_KEY" | b64url_decode | od -An -tx1 -v | tr -d " \n" > "$TMP_LIC/pub.hex"
    {
        printf '302a300506032b6570032100'
        cat "$TMP_LIC/pub.hex"
    } | hex_to_binary > "$TMP_LIC/pub.der"

    if ! openssl pkeyutl -verify -pubin -keyform DER \
            -inkey "$TMP_LIC/pub.der" -rawin \
            -in "$TMP_LIC/payload" -sigfile "$TMP_LIC/sig" >/dev/null 2>&1; then
        die "授权签名校验失败（密钥无效或被篡改）"
    fi

    expires="$(cut -d"|" -f3 < "$TMP_LIC/payload")"
    case "$expires" in
        '' | *[!0-9]*) die "授权到期字段无效" ;;
    esac
    now="$(date +%s)"
    [ "$now" -le "$expires" ] || die "授权已于 $(epoch_date "$expires") 到期"

    customer="$(cut -d"|" -f2 < "$TMP_LIC/payload")"
    max_installs="$(cut -d"|" -f4 < "$TMP_LIC/payload")"
    expires_date="$(epoch_date "$expires")"
    max_display="${max_installs:-0}"
    [ "$max_display" != "0" ] || max_display="不限"
    rm -rf "$TMP_LIC"
    trap - EXIT HUP INT TERM

    log "授权核验通过"
    log "授权状态: 有效"
    log "客户名称: ${customer:-未命名}"
    log "到期时间: $expires_date"
    log "最大安装数: $max_display"
    log "授权密钥: $(mask_license "$FRPW_LICENSE")"
)

sha256_file() {
    file="$1"
    if have sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        die "需要 sha256sum 或 shasum"
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
    log "下载 SHA256SUMS ..."
    if ! download_file "$base/SHA256SUMS" "$sums" progress; then
        return 1
    fi
    log "下载完成: SHA256SUMS ($(human_size "$(file_size "$sums")"))"
    if ! verify_sha256 "$sums" "$EXPECTED_SUMS_SHA256"; then
        warn "镜像校验清单验证失败: $base"
        return 1
    fi
    log "下载 install.sh ..."
    if ! download_file "$base/install.sh" "$installer" progress; then
        return 1
    fi
    log "下载完成: install.sh ($(human_size "$(file_size "$installer")"))"
    if ! verify_sha256 "$installer" "$EXPECTED_INSTALL_SHA256"; then
        warn "镜像安装脚本验证失败: $base"
        return 1
    fi
    return 0
}

main() {
    license_block=""
    case "$COMPONENT" in
        server)
            [ -n "$FRPW_LICENSE" ] || die "此发行版为付费授权：请设置 FRPW_LICENSE 授权密钥，例如
  curl -fsSL <install-cn.sh 地址> | sudo FRPW_LICENSE=FRPW-xxx... sh -s -- server
请联系供应商购买授权。"
            log "授权密钥: $(mask_license "$FRPW_LICENSE")"
            log "正在下载安装脚本: Ed25519 验签通过后将显示客户名称、到期时间与最大安装数"
            log "下载过程中会显示进度条，请稍候..."
            license_block="$(verify_license)"
            ;;
    esac
    TMP_DIR="$(mktemp -d)"
    sums="$TMP_DIR/SHA256SUMS"
    installer="$TMP_DIR/install.sh"
    for base in $(mirror_bases); do
        base="${base%/}"
        log "尝试镜像: $base"
        if prepare_mirror "$base" "$sums" "$installer"; then
            log "镜像验证通过: $base"
            log "发行包下载与安装脚本同源: $(mirror_origin "$base")"
            if [ -n "$license_block" ]; then
                printf '%s\n' "$license_block"
            fi
            FRPW_LICENSE="$FRPW_LICENSE" \
                FRPW_LICENSE_INFO_SHOWN=1 \
                FRPW_DOWNLOAD_BASE_URL="$base" \
                FRPW_USE_GITHUB_API=0 \
                FRPW_VERSION="$FRPW_VERSION" \
                sh "$installer" "$@"
            exit $?
        fi
        warn "镜像不可用或校验失败: $base"
    done
    die "所有国内镜像均不可用；请使用标准安装脚本，或设置 FRPW_CN_MIRROR_BASE_URL"
}

main "$@"
