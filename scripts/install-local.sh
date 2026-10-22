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
        die "需要 sha256sum 或 shasum"
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
        *) die "不支持的 CPU 架构: $(uname -m)" ;;
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
  sudo FRPW_LICENSE=FRPW-xxx... sh install-local.sh server
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

# The release directory defaults to the directory containing this script so
# the common "upload everything into one folder" flow needs no variables.
SCRIPT_DIR=""
if [ -n "${0:-}" ] && [ -f "$0" ]; then
    SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)"
fi
RELEASE_DIR="${FRPW_RELEASE_DIR:-${SCRIPT_DIR:-$PWD}}"

[ "$(uname -s)" = "Linux" ] || die "install-local.sh 仅支持 Linux"
case "$COMPONENT" in
    server | node | agent) ;;
    *) die "组件必须是 server、node 或 agent" ;;
esac
[ -d "$RELEASE_DIR" ] || die "发行目录不存在: $RELEASE_DIR"
[ -f "$RELEASE_DIR/SHA256SUMS" ] || die "$RELEASE_DIR 缺少 SHA256SUMS（请与二进制一起上传）"
[ -f "$RELEASE_DIR/install.sh" ] || die "$RELEASE_DIR 缺少 install.sh（请与本脚本一起上传）"

case "$COMPONENT" in
    server)
        [ -n "$FRPW_LICENSE" ] || die "此发行版为付费授权：请设置 FRPW_LICENSE 授权密钥，例如
  sudo FRPW_LICENSE=FRPW-xxx... sh install-local.sh server
请联系供应商购买授权。"
        log "授权密钥: $(mask_license "$FRPW_LICENSE")"
        log "正在校验离线发行包: Ed25519 验签通过后将显示客户名称、到期时间与最大安装数"
        ;;
esac

ARCH="$(detect_arch)"
REQUIRED="frpw-$COMPONENT-$FRPW_VERSION-linux-$ARCH"

# Server mode also installs the managed client/node catalog when the files
# are present locally; warn instead of failing so minimal uploads still work.
OPTIONAL=""
if [ "$COMPONENT" = "server" ]; then
    OPTIONAL="frpw-client-$FRPW_VERSION-linux-amd64 frpw-client-$FRPW_VERSION-linux-arm64 frpw-client-$FRPW_VERSION-windows-amd64.exe frpw-client-$FRPW_VERSION-darwin-amd64 frpw-client-$FRPW_VERSION-darwin-arm64 frpw-node-$FRPW_VERSION-linux-amd64 frpw-node-$FRPW_VERSION-linux-arm64"
fi

log "校验发行文件: $RELEASE_DIR"
[ -f "$RELEASE_DIR/$REQUIRED" ] || die "缺少必需的二进制文件: $RELEASE_DIR/$REQUIRED"

EXPECTED="$(checksum_for_asset "$REQUIRED" "$RELEASE_DIR/SHA256SUMS")"
[ -n "$EXPECTED" ] || die "SHA256SUMS 中没有 $REQUIRED 的有效校验值"
ACTUAL="$(sha256_file "$RELEASE_DIR/$REQUIRED")"
[ "$ACTUAL" = "$EXPECTED" ] || die "$REQUIRED 校验失败（文件损坏或被篡改）"
log "SHA256 验证通过: $REQUIRED ($(human_size "$(file_size "$RELEASE_DIR/$REQUIRED")"))"

MISSING_OPTIONAL=""
for name in $OPTIONAL; do
    if [ -f "$RELEASE_DIR/$name" ]; then
        expected="$(checksum_for_asset "$name" "$RELEASE_DIR/SHA256SUMS")"
        actual="$(sha256_file "$RELEASE_DIR/$name")"
        [ -n "$expected" ] && [ "$actual" = "$expected" ] || die "$name 校验失败（文件损坏或被篡改）"
        log "SHA256 验证通过: $name ($(human_size "$(file_size "$RELEASE_DIR/$name")"))"
    else
        MISSING_OPTIONAL="$MISSING_OPTIONAL $name"
    fi
done
if [ -n "$MISSING_OPTIONAL" ]; then
    warn "可选目录文件未上传，托管客户端/节点下载将受限:$MISSING_OPTIONAL"
fi

case "$COMPONENT" in
    server) verify_license ;;
esac

log "离线发行包校验完成，开始安装 FRPW $COMPONENT $FRPW_VERSION"
FRPW_LICENSE_INFO_SHOWN=1 FRPW_LICENSE="$FRPW_LICENSE" FRPW_LOCAL_DIR="$RELEASE_DIR" FRPW_VERSION="$FRPW_VERSION" sh "$RELEASE_DIR/install.sh" "$COMPONENT"
