#!/usr/bin/env sh
set -eu

COMPONENT="${1:-${FRPW_COMPONENT:-server}}"
FRPW_REPO="${FRPW_REPO:-ccmaoxiong/frpw}"
FRPW_VERSION="${FRPW_VERSION:-v1.0.2}"
FRPW_GITHUB_API_URL="${FRPW_GITHUB_API_URL:-https://api.github.com}"
FRPW_GITHUB_DOWNLOAD_URL="${FRPW_GITHUB_DOWNLOAD_URL:-https://github.com}"
FRPW_DOWNLOAD_BASE_URL="${FRPW_DOWNLOAD_BASE_URL:-}"
FRPW_LOCAL_DIR="${FRPW_LOCAL_DIR:-}"
FRPW_TOKEN="${FRPW_TOKEN:-${GITHUB_TOKEN:-}}"
FRPW_USE_GITHUB_API="${FRPW_USE_GITHUB_API:-}"
FRPW_CONNECT_TIMEOUT="${FRPW_CONNECT_TIMEOUT:-15}"
FRPW_MAX_TIME="${FRPW_MAX_TIME:-600}"
FRPW_RETRIES="${FRPW_RETRIES:-5}"
FRPW_NO_PROGRESS="${FRPW_NO_PROGRESS:-0}"
RELEASE_JSON=""
FRPW_SERVICE_USER="${FRPW_SERVICE_USER:-frpw}"

# Extra Environment= line injected into the systemd unit (server only).
UNIT_ENVIRONMENT=""

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

case "$FRPW_USE_GITHUB_API" in
    "")
        if [ -n "$FRPW_TOKEN" ]; then
            FRPW_USE_GITHUB_API=1
        else
            FRPW_USE_GITHUB_API=0
        fi
        ;;
    1 | true | yes) FRPW_USE_GITHUB_API=1 ;;
    *) FRPW_USE_GITHUB_API=0 ;;
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

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请以 root 权限运行此安装脚本"
    fi
}

have() {
    command -v "$1" >/dev/null 2>&1
}

validate_url() {
    url="$1"
    case "$url" in
        http://* | https://*) ;;
        *) die "无效的下载地址: $url" ;;
    esac
    case "$url" in
        *[[:space:]]*) die "下载地址包含空白或控制字符" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) printf '%s' "amd64" ;;
        aarch64 | arm64) printf '%s' "arm64" ;;
        *) die "不支持的 CPU 架构: $(uname -m)" ;;
    esac
}

http_get() {
    url="$1"
    accept="${2:-application/vnd.github+json}"
    validate_url "$url"
    if have curl; then
        if [ -n "$FRPW_TOKEN" ]; then
            curl --http1.1 -fsSL --location --retry "$FRPW_RETRIES" --retry-delay 2 \
                --connect-timeout "$FRPW_CONNECT_TIMEOUT" --max-time "$FRPW_MAX_TIME" \
                -H "Authorization: Bearer $FRPW_TOKEN" \
                -H "Accept: $accept" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                -H "User-Agent: frpw-installer" \
                "$url"
        else
            curl --http1.1 -fsSL --location --retry "$FRPW_RETRIES" --retry-delay 2 \
                --connect-timeout "$FRPW_CONNECT_TIMEOUT" --max-time "$FRPW_MAX_TIME" \
                -H "Accept: $accept" \
                -H "User-Agent: frpw-installer" \
                "$url"
        fi
        return
    fi
    if have wget; then
        if [ -n "$FRPW_TOKEN" ]; then
            wget -qO- --tries="$FRPW_RETRIES" --timeout="$FRPW_CONNECT_TIMEOUT" \
                --header="Authorization: Bearer $FRPW_TOKEN" \
                --header="Accept: $accept" \
                --header="X-GitHub-Api-Version: 2022-11-28" \
                --header="User-Agent: frpw-installer" \
                "$url"
        else
            wget -qO- --tries="$FRPW_RETRIES" --timeout="$FRPW_CONNECT_TIMEOUT" \
                --header="Accept: $accept" \
                --header="User-Agent: frpw-installer" \
                "$url"
        fi
        return
    fi
    die "需要 curl 或 wget"
}

download_file() {
    url="$1"
    destination="$2"
    accept="${3:-application/octet-stream}"
    validate_url "$url"
    temporary="$destination.part"
    rm -f "$temporary"
    # Release binaries pass "progress" as the 4th argument. Draw the bar only
    # on an interactive terminal so piped logs and CI output stay clean.
    curl_flags="-fsSL"
    wget_flags="-q"
    if [ "${4:-}" = "progress" ] && [ "$FRPW_NO_PROGRESS" != "1" ] && [ -t 2 ]; then
        curl_flags="-fSL --progress-bar"
        # Let wget draw its native meter; --progress is not portable to busybox.
        wget_flags=""
    fi
    if have curl; then
        if [ -n "$FRPW_TOKEN" ]; then
            if curl --http1.1 $curl_flags --location --retry "$FRPW_RETRIES" --retry-delay 2 \
                --connect-timeout "$FRPW_CONNECT_TIMEOUT" --max-time "$FRPW_MAX_TIME" \
                -H "Authorization: Bearer $FRPW_TOKEN" \
                -H "Accept: $accept" \
                -H "User-Agent: frpw-installer" \
                -o "$temporary" \
                "$url"; then
                :
            else
                rm -f "$temporary"
                return 1
            fi
        else
            if curl --http1.1 $curl_flags --location --retry "$FRPW_RETRIES" --retry-delay 2 \
                --connect-timeout "$FRPW_CONNECT_TIMEOUT" --max-time "$FRPW_MAX_TIME" \
                -H "Accept: $accept" \
                -H "User-Agent: frpw-installer" \
                -o "$temporary" \
                "$url"; then
                :
            else
                rm -f "$temporary"
                return 1
            fi
        fi
        if [ -s "$temporary" ]; then
            mv -f "$temporary" "$destination"
            return 0
        fi
        rm -f "$temporary"
        return 1
    fi
    if have wget; then
        if [ -n "$FRPW_TOKEN" ]; then
            if wget $wget_flags -O "$temporary" --tries="$FRPW_RETRIES" --timeout="$FRPW_CONNECT_TIMEOUT" \
                --header="Authorization: Bearer $FRPW_TOKEN" \
                --header="Accept: $accept" \
                --header="User-Agent: frpw-installer" \
                "$url"; then
                :
            else
                rm -f "$temporary"
                return 1
            fi
        else
            if wget $wget_flags -O "$temporary" --tries="$FRPW_RETRIES" --timeout="$FRPW_CONNECT_TIMEOUT" \
                --header="Accept: $accept" \
                --header="User-Agent: frpw-installer" \
                "$url"; then
                :
            else
                rm -f "$temporary"
                return 1
            fi
        fi
        if [ -s "$temporary" ]; then
            mv -f "$temporary" "$destination"
            return 0
        fi
        rm -f "$temporary"
        return 1
    fi
    die "需要 curl 或 wget"
}

load_release() {
    if [ -n "$FRPW_DOWNLOAD_BASE_URL" ]; then
        return
    fi
    if [ "$FRPW_USE_GITHUB_API" != "1" ]; then
        return
    fi
    api_base="${FRPW_GITHUB_API_URL%/}"
    if RELEASE_JSON="$(http_get "$api_base/repos/$FRPW_REPO/releases/tags/$FRPW_VERSION")" && [ -n "$RELEASE_JSON" ]; then
        return
    fi
    RELEASE_JSON=""
    warn "GitHub 发行信息不可用，改用公共下载地址"
}

asset_id() {
    asset_name="$1"
    printf '%s\n' "$RELEASE_JSON" | tr ',' '\n' | tr -d '\r' | awk -v wanted="\"name\":\"$asset_name\"" '
        /"id":[[:space:]]*[0-9]+/ {
            line = $0
            sub(/^.*"id":[[:space:]]*/, "", line)
            sub(/[^0-9].*$/, "", line)
            id = line
        }
        index($0, wanted) > 0 {
            print id
            exit
        }
    '
}

# Local/offline mode: when FRPW_LOCAL_DIR points at a directory of release
# binaries (set by install-local.sh), install from disk after the same SHA256
# verification used for remote downloads.
if [ -n "$FRPW_LOCAL_DIR" ]; then
    [ -d "$FRPW_LOCAL_DIR" ] || die "FRPW_LOCAL_DIR 不是目录: $FRPW_LOCAL_DIR"
    [ -f "$FRPW_LOCAL_DIR/SHA256SUMS" ] || die "FRPW_LOCAL_DIR 缺少 SHA256SUMS: $FRPW_LOCAL_DIR"
fi

download_asset() {
    asset_name="$1"
    destination="$2"
    if [ -n "$FRPW_LOCAL_DIR" ]; then
        [ -f "$FRPW_LOCAL_DIR/$asset_name" ] || die "本地发行文件缺失: $FRPW_LOCAL_DIR/$asset_name"
        log "使用本地发行文件: $asset_name ($(human_size "$(file_size "$FRPW_LOCAL_DIR/$asset_name")"))"
        cp -f "$FRPW_LOCAL_DIR/$asset_name" "$destination"
        return 0
    fi
    log "下载 $asset_name ..."
    download_base="${FRPW_DOWNLOAD_BASE_URL%/}"
    if [ -n "$download_base" ]; then
        download_file "$download_base/$asset_name" "$destination" application/octet-stream progress || return 1
        log "下载完成: $asset_name ($(human_size "$(file_size "$destination")"))"
        return 0
    fi
    id=""
    if [ "$FRPW_USE_GITHUB_API" = "1" ] && [ -n "$RELEASE_JSON" ]; then
        id="$(asset_id "$asset_name")"
    fi
    case "$id" in
        '' | *[!0-9]*) id="" ;;
    esac
    api_base="${FRPW_GITHUB_API_URL%/}"
    if [ -n "$id" ] && download_file "$api_base/repos/$FRPW_REPO/releases/assets/$id" "$destination" application/octet-stream progress; then
        log "下载完成: $asset_name ($(human_size "$(file_size "$destination")"))"
        return 0
    fi
    [ -z "$id" ] || warn "GitHub API 下载失败: $asset_name，改用公共下载地址"
    github_download_base="${FRPW_GITHUB_DOWNLOAD_URL%/}"
    download_file "$github_download_base/$FRPW_REPO/releases/download/$FRPW_VERSION/$asset_name" "$destination" application/octet-stream progress || return 1
    log "下载完成: $asset_name ($(human_size "$(file_size "$destination")"))"
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

download_checksums() {
    destination="$1"
    manifest_asset="frpw-server-$FRPW_VERSION-linux-amd64"
    if [ -n "$FRPW_LOCAL_DIR" ]; then
        cp -f "$FRPW_LOCAL_DIR/SHA256SUMS" "$destination"
        [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ] || die "本地 SHA256SUMS 无效"
        log "使用本地校验清单: SHA256SUMS ($(human_size "$(file_size "$destination")"))"
        return 0
    fi
    log "下载 SHA256SUMS ..."
    download_base="${FRPW_DOWNLOAD_BASE_URL%/}"
    if [ -n "$download_base" ]; then
        download_file "$download_base/SHA256SUMS" "$destination" application/octet-stream progress || return 1
        log "下载完成: SHA256SUMS ($(human_size "$(file_size "$destination")"))"
        [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ] || die "下载的 SHA256SUMS 无效"
        return 0
    fi
    id=""
    if [ "$FRPW_USE_GITHUB_API" = "1" ] && [ -n "$RELEASE_JSON" ]; then
        id="$(asset_id "SHA256SUMS")"
    fi
    case "$id" in
        '' | *[!0-9]*) id="" ;;
    esac
    api_base="${FRPW_GITHUB_API_URL%/}"
    if [ -n "$id" ] && download_file "$api_base/repos/$FRPW_REPO/releases/assets/$id" "$destination" application/octet-stream progress && [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ]; then
        log "下载完成: SHA256SUMS ($(human_size "$(file_size "$destination")"))"
        return 0
    fi
    [ -z "$id" ] || warn "GitHub API 校验清单下载无效，改用公共下载地址"
    github_download_base="${FRPW_GITHUB_DOWNLOAD_URL%/}"
    download_file "$github_download_base/$FRPW_REPO/releases/download/$FRPW_VERSION/SHA256SUMS" "$destination" application/octet-stream progress || return 1
    log "下载完成: SHA256SUMS ($(human_size "$(file_size "$destination")"))"
    [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ] || die "下载的 SHA256SUMS 无效"
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
  curl -fsSL <install.sh 地址> | sudo FRPW_LICENSE=FRPW-xxx... sh -s -- server
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

    if [ "${FRPW_LICENSE_INFO_SHOWN:-0}" = "1" ]; then
        return 0
    fi
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

verify_asset() {
    asset_name="$1"
    file="$2"
    sums="$3"
    expected="$(checksum_for_asset "$asset_name" "$sums")"
    [ -n "$expected" ] || die "SHA256SUMS 中没有 $asset_name 的有效校验值"
    actual="$(sha256_file "$file")"
    if [ "$actual" != "$expected" ]; then
        die "$asset_name 校验失败（文件损坏或被篡改）"
    fi
}

generate_secret() {
    if have openssl; then
        openssl rand -hex 32
        return
    fi
    if [ -r /dev/urandom ] && have od; then
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
        return
    fi
    die "无法生成安全的 JWT 密钥，请安装 openssl 或设置 FRPW_JWT_SECRET"
}

ensure_user() {
    if id -u "$FRPW_SERVICE_USER" >/dev/null 2>&1; then
        return
    fi
    if have useradd; then
        useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$FRPW_SERVICE_USER"
    elif have adduser; then
        adduser -S -D -H -h "$INSTALL_DIR" -s /sbin/nologin "$FRPW_SERVICE_USER"
    else
        die "请创建系统用户 $FRPW_SERVICE_USER，或设置 FRPW_SERVICE_USER"
    fi
}

write_systemd_unit() {
    unit_path="/etc/systemd/system/$SERVICE_NAME.service"
    cat > "$unit_path" <<EOF
[Unit]
Description=FRPW $COMPONENT service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$FRPW_SERVICE_USER
Group=$FRPW_SERVICE_USER
WorkingDirectory=$INSTALL_DIR
$UNIT_ENVIRONMENT
ExecStart=$EXEC_START
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$unit_path"
    if have systemctl; then
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME"
        systemctl restart "$SERVICE_NAME"
        log "systemd 服务已启动: $SERVICE_NAME"
    else
        warn "未找到 systemd，请手动启动: $EXEC_START"
    fi
}

install_binary() {
    asset_name="$1"
    binary_path="$2"
    download_asset "$asset_name" "$TMP_DIR/$asset_name"
    verify_asset "$asset_name" "$TMP_DIR/$asset_name" "$TMP_DIR/SHA256SUMS"
    log "$asset_name SHA256 验证通过"
    install -m 0755 "$TMP_DIR/$asset_name" "$binary_path"
    log "程序已安装: $binary_path"
}

download_client_catalog() {
    client_dir="$DATA_DIR/client-releases"
    install -d -m 0755 "$client_dir"
    # The server looks up fixed, version-less filenames (see
    # internal/api/client.go), so each asset is installed under its
    # catalog name rather than the release asset name.
    for pair in \
        "frpw-client-$FRPW_VERSION-linux-amd64:frpw-client-linux-amd64" \
        "frpw-client-$FRPW_VERSION-linux-arm64:frpw-client-linux-arm64" \
        "frpw-client-$FRPW_VERSION-windows-amd64.exe:frpw-client-windows-amd64.exe" \
        "frpw-client-$FRPW_VERSION-darwin-amd64:frpw-client-darwin-amd64" \
        "frpw-client-$FRPW_VERSION-darwin-arm64:frpw-client-darwin-arm64" \
        "frpw-node-$FRPW_VERSION-linux-amd64:frpw-node-linux-amd64" \
        "frpw-node-$FRPW_VERSION-linux-arm64:frpw-node-linux-arm64"; do
        asset_name="${pair%%:*}"
        catalog_name="${pair##*:}"
        if download_asset "$asset_name" "$TMP_DIR/$asset_name"; then
            verify_asset "$asset_name" "$TMP_DIR/$asset_name" "$TMP_DIR/SHA256SUMS"
            install -m 0755 "$TMP_DIR/$asset_name" "$client_dir/$catalog_name"
        else
            warn "可选发行文件不可用: $asset_name"
        fi
    done
    install -m 0644 "$TMP_DIR/SHA256SUMS" "$client_dir/SHA256SUMS"
    log "客户端与节点目录已安装: $client_dir"
}

install_server() {
    INSTALL_DIR="${FRPW_INSTALL_DIR:-/opt/frpw}"
    DATA_DIR="${FRPW_DATA_DIR:-/var/lib/frpw}"
    CONFIG_DIR="${FRPW_CONFIG_DIR:-/etc/frpw}"
    CONFIG_FILE="$CONFIG_DIR/server.yaml"
    SERVICE_NAME="frpw"
    API_ADDR="${FRPW_API_ADDR:-:9000}"
    AGENT_ADDR="${FRPW_AGENT_ADDR:-:7000}"
    PUBLIC_HTTP_ADDR="${FRPW_PUBLIC_HTTP_ADDR:-:8080}"
    PUBLIC_HTTP_PORT="${FRPW_PUBLIC_HTTP_PORT:-8080}"
    PORT_RANGE_FROM="${FRPW_PORT_RANGE_FROM:-20000}"
    PORT_RANGE_TO="${FRPW_PORT_RANGE_TO:-20999}"
    BASE_DOMAIN="${FRPW_BASE_DOMAIN:-localhost}"
    AGENT_PUBLIC_ADDR="${FRPW_AGENT_PUBLIC_ADDR:-}"
    ADMIN_PATH="${FRPW_ADMIN_PATH:-/admin-panel}"
    ALLOW_REGISTRATION="${FRPW_ALLOW_REGISTRATION:-true}"

    install -d -m 0755 "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"
    ensure_user

    # Persist the paid license key so the server binary re-verifies it on every
    # start and every 6 hours, independent of this installer run.
    license_file="${FRPW_LICENSE_FILE:-$CONFIG_DIR/license.key}"
    printf '%s\n' "$FRPW_LICENSE" > "$license_file"
    if chown root:"$FRPW_SERVICE_USER" "$license_file" 2>/dev/null; then
        chmod 0640 "$license_file"
    else
        chown "$FRPW_SERVICE_USER" "$license_file"
        chmod 0600 "$license_file"
    fi
    UNIT_ENVIRONMENT="Environment=FRPW_LICENSE_FILE=$license_file"
    log "授权密钥已写入: $license_file"
    install_binary "frpw-server-$FRPW_VERSION-linux-$(detect_arch)" "$INSTALL_DIR/frpw-server"

    if [ ! -f "$CONFIG_FILE" ]; then
        jwt_secret="${FRPW_JWT_SECRET:-$(generate_secret)}"
        cat > "$CONFIG_FILE" <<EOF
data_dir: "$DATA_DIR"
api_addr: "$API_ADDR"
agent_addr: "$AGENT_ADDR"
agent_public_addr: "$AGENT_PUBLIC_ADDR"
client_release_dir: "$DATA_DIR/client-releases"
public_http_addr: "$PUBLIC_HTTP_ADDR"
public_http_port: $PUBLIC_HTTP_PORT
base_domain: "$BASE_DOMAIN"
port_range_from: $PORT_RANGE_FROM
port_range_to: $PORT_RANGE_TO
jwt_secret: "$jwt_secret"
session_ttl: 12h
meter_interval: 30s
platform_admins:
  - admin@example.com
admin_console_path: "$ADMIN_PATH"
allow_registration: $ALLOW_REGISTRATION
log_level: info
payment:
  allow_mock: false
EOF
        chmod 0600 "$CONFIG_FILE"
        log "已生成配置文件: $CONFIG_FILE"
    else
        log "保留已有配置文件: $CONFIG_FILE (如需改端口请编辑该文件后重启服务)"
    fi

    download_client_catalog
    chown -R "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$INSTALL_DIR" "$DATA_DIR"
    [ -f "$CONFIG_FILE" ] && chown "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$CONFIG_FILE"
    EXEC_START="$INSTALL_DIR/frpw-server -config $CONFIG_FILE"
    write_systemd_unit

    log "FRPW 服务端 $FRPW_VERSION 安装完成"
    log "用户端地址: http://<服务器IP>:${API_ADDR##*:}"
    log "管理端地址: http://<服务器IP>:${API_ADDR##*:}$ADMIN_PATH"
    log "默认管理员: admin@example.com / admin12345（请立即修改）"
    log "默认用户: user@example.com / user12345（请立即修改）"
    warn "请确保公网 HTTP 端口 ${PUBLIC_HTTP_PORT} 与 Agent 端口 ${AGENT_ADDR##*:} 已在防火墙放行"
}

install_agent() {
    INSTALL_DIR="${FRPW_AGENT_INSTALL_DIR:-/opt/frpw-agent}"
    DATA_DIR="${FRPW_AGENT_DATA_DIR:-/var/lib/frpw-agent}"
    CONFIG_DIR="${FRPW_AGENT_CONFIG_DIR:-/etc/frpw-agent}"
    CONFIG_FILE="$CONFIG_DIR/agent.yaml"
    SERVICE_NAME="frpw-agent"
    AGENT_SERVER="${FRPW_SERVER:-}"
    AGENT_TOKEN_VALUE="${FRPW_AGENT_TOKEN:-}"
    CONTROL_PLANE="${FRPW_CONTROL_PLANE:-}"
    AGENT_ID="${FRPW_AGENT_ID:-$(hostname)}"
    NODE_ID="${FRPW_NODE_ID:-node_local}"

    [ -n "$AGENT_SERVER" ] || die "未设置 FRPW_SERVER，例如 FRPW_SERVER=203.0.113.10:7000"
    [ -n "$AGENT_TOKEN_VALUE" ] || die "未设置 FRPW_AGENT_TOKEN"
    [ -n "$CONTROL_PLANE" ] || die "未设置 FRPW_CONTROL_PLANE，例如 https://console.example.com"

    install -d -m 0755 "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"
    ensure_user
    install_binary "frpw-agent-$FRPW_VERSION-linux-$(detect_arch)" "$INSTALL_DIR/frpw-agent"

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
server: "$AGENT_SERVER"
control_plane: "$CONTROL_PLANE"
token: "$AGENT_TOKEN_VALUE"
agent_id: "$AGENT_ID"
node_id: "$NODE_ID"
auto_sync_interval: 30s
dial_timeout: 10s
max_backoff: 30s
tunnels: []
EOF
        chmod 0600 "$CONFIG_FILE"
        log "已生成配置文件: $CONFIG_FILE"
    else
        log "保留已有配置文件: $CONFIG_FILE (如需改端口请编辑该文件后重启服务)"
    fi

    chown -R "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$INSTALL_DIR" "$DATA_DIR"
    chown "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$CONFIG_FILE"
    EXEC_START="$INSTALL_DIR/frpw-agent -headless -config $CONFIG_FILE"
    write_systemd_unit
    log "FRPW Agent $FRPW_VERSION 安装完成，节点: $NODE_ID"
}

install_node() {
    INSTALL_DIR="${FRPW_NODE_INSTALL_DIR:-/opt/frpw-node}"
    DATA_DIR="${FRPW_NODE_DATA_DIR:-/var/lib/frpw-node}"
    CONFIG_DIR="${FRPW_NODE_CONFIG_DIR:-/etc/frpw-node}"
    CONFIG_FILE="$CONFIG_DIR/node.yaml"
    SERVICE_NAME="frpw-node"
    CONTROL_PLANE="${FRPW_CONTROL_PLANE:-}"
    NODE_TOKEN_VALUE="${FRPW_NODE_TOKEN:-}"
    NODE_AGENT_ADDR="${FRPW_NODE_AGENT_ADDR:-:7000}"
    NODE_HTTP_ADDR="${FRPW_NODE_HTTP_ADDR:-:8080}"
    NODE_PUBLIC_HTTP_PORT="${FRPW_NODE_PUBLIC_HTTP_PORT:-8080}"
    NODE_BASE_DOMAIN="${FRPW_NODE_BASE_DOMAIN:-localhost}"
    NODE_PORT_RANGE_FROM="${FRPW_NODE_PORT_RANGE_FROM:-20000}"
    NODE_PORT_RANGE_TO="${FRPW_NODE_PORT_RANGE_TO:-20999}"

    [ -n "$CONTROL_PLANE" ] || die "未设置 FRPW_CONTROL_PLANE，例如 https://console.example.com"
    [ -n "$NODE_TOKEN_VALUE" ] || die "未设置 FRPW_NODE_TOKEN"

    install -d -m 0755 "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"
    ensure_user
    install_binary "frpw-node-$FRPW_VERSION-linux-$(detect_arch)" "$INSTALL_DIR/frpw-node"

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
control_plane: "$CONTROL_PLANE"
token: "$NODE_TOKEN_VALUE"
version: "$FRPW_VERSION"
agent_addr: "$NODE_AGENT_ADDR"
http_addr: "$NODE_HTTP_ADDR"
public_http_port: $NODE_PUBLIC_HTTP_PORT
base_domain: "$NODE_BASE_DOMAIN"
port_range_from: $NODE_PORT_RANGE_FROM
port_range_to: $NODE_PORT_RANGE_TO
heartbeat_interval: 15s
tunnel_timeout: 30s
log_level: info
EOF
        chmod 0600 "$CONFIG_FILE"
        log "已生成配置文件: $CONFIG_FILE"
    else
        log "保留已有配置文件: $CONFIG_FILE (如需改端口请编辑该文件后重启服务)"
    fi

    chown -R "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$INSTALL_DIR" "$DATA_DIR"
    chown "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$CONFIG_FILE"
    EXEC_START="$INSTALL_DIR/frpw-node -config $CONFIG_FILE"
    write_systemd_unit
    log "FRPW 远程节点 $FRPW_VERSION 安装完成"
}

main() {
    need_root
    [ "$(uname -s)" = "Linux" ] || die "install.sh 仅支持 Linux"
    case "$COMPONENT" in
        server)
            if [ "${FRPW_LICENSE_INFO_SHOWN:-0}" != "1" ] && [ -n "$FRPW_LICENSE" ]; then
                log "授权密钥: $(mask_license "$FRPW_LICENSE")"
            fi
            verify_license
            ;;
    esac
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
    if [ -n "$FRPW_LOCAL_DIR" ]; then
        log "使用本地发行目录安装: $FRPW_LOCAL_DIR"
    else
        load_release
    fi
    download_checksums "$TMP_DIR/SHA256SUMS"

    case "$COMPONENT" in
        server) install_server ;;
        agent) install_agent ;;
        node) install_node ;;
        *) die "组件必须是 server、agent 或 node" ;;
    esac
}

main "$@"
