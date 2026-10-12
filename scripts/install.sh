#!/usr/bin/env sh
set -eu

COMPONENT="${1:-${FRPW_COMPONENT:-server}}"
FRPW_REPO="${FRPW_REPO:-ccmaoxiong/frpw}"
FRPW_VERSION="${FRPW_VERSION:-v1.0.1}"
FRPW_GITHUB_API_URL="${FRPW_GITHUB_API_URL:-https://api.github.com}"
FRPW_GITHUB_DOWNLOAD_URL="${FRPW_GITHUB_DOWNLOAD_URL:-https://github.com}"
FRPW_DOWNLOAD_BASE_URL="${FRPW_DOWNLOAD_BASE_URL:-}"
FRPW_LOCAL_DIR="${FRPW_LOCAL_DIR:-}"
FRPW_TOKEN="${FRPW_TOKEN:-${GITHUB_TOKEN:-}}"
FRPW_USE_GITHUB_API="${FRPW_USE_GITHUB_API:-}"
FRPW_CONNECT_TIMEOUT="${FRPW_CONNECT_TIMEOUT:-15}"
FRPW_MAX_TIME="${FRPW_MAX_TIME:-600}"
FRPW_RETRIES="${FRPW_RETRIES:-5}"
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
    printf '%s\n' "warning: $*" >&2
}

die() {
    printf '%s\n' "error: $*" >&2
    exit 1
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "run this installer as root"
    fi
}

have() {
    command -v "$1" >/dev/null 2>&1
}

validate_url() {
    url="$1"
    case "$url" in
        http://* | https://*) ;;
        *) die "invalid download URL: $url" ;;
    esac
    case "$url" in
        *[[:space:]]*) die "download URL contains whitespace or control characters" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) printf '%s' "amd64" ;;
        aarch64 | arm64) printf '%s' "arm64" ;;
        *) die "unsupported architecture: $(uname -m)" ;;
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
    die "curl or wget is required"
}

download_file() {
    url="$1"
    destination="$2"
    accept="${3:-application/octet-stream}"
    validate_url "$url"
    temporary="$destination.part"
    rm -f "$temporary"
    if have curl; then
        if [ -n "$FRPW_TOKEN" ]; then
            if curl --http1.1 -fsSL --location --retry "$FRPW_RETRIES" --retry-delay 2 \
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
            if curl --http1.1 -fsSL --location --retry "$FRPW_RETRIES" --retry-delay 2 \
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
            if wget -qO "$temporary" --tries="$FRPW_RETRIES" --timeout="$FRPW_CONNECT_TIMEOUT" \
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
            if wget -qO "$temporary" --tries="$FRPW_RETRIES" --timeout="$FRPW_CONNECT_TIMEOUT" \
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
    die "curl or wget is required"
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
    warn "GitHub release metadata unavailable; falling back to public download URLs"
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
    [ -d "$FRPW_LOCAL_DIR" ] || die "FRPW_LOCAL_DIR is not a directory: $FRPW_LOCAL_DIR"
    [ -f "$FRPW_LOCAL_DIR/SHA256SUMS" ] || die "FRPW_LOCAL_DIR is missing SHA256SUMS: $FRPW_LOCAL_DIR"
fi

download_asset() {
    asset_name="$1"
    destination="$2"
    if [ -n "$FRPW_LOCAL_DIR" ]; then
        [ -f "$FRPW_LOCAL_DIR/$asset_name" ] || die "local release asset missing: $FRPW_LOCAL_DIR/$asset_name"
        cp -f "$FRPW_LOCAL_DIR/$asset_name" "$destination"
        return
    fi
    download_base="${FRPW_DOWNLOAD_BASE_URL%/}"
    if [ -n "$download_base" ]; then
        download_file "$download_base/$asset_name" "$destination"
        return
    fi
    id=""
    if [ "$FRPW_USE_GITHUB_API" = "1" ] && [ -n "$RELEASE_JSON" ]; then
        id="$(asset_id "$asset_name")"
    fi
    case "$id" in
        '' | *[!0-9]*) id="" ;;
    esac
    api_base="${FRPW_GITHUB_API_URL%/}"
    if [ -n "$id" ] && download_file "$api_base/repos/$FRPW_REPO/releases/assets/$id" "$destination"; then
        return
    fi
    [ -z "$id" ] || warn "GitHub API download failed for $asset_name; trying public download URL"
    github_download_base="${FRPW_GITHUB_DOWNLOAD_URL%/}"
    download_file "$github_download_base/$FRPW_REPO/releases/download/$FRPW_VERSION/$asset_name" "$destination"
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
        [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ] || die "local SHA256SUMS is invalid"
        return
    fi
    download_base="${FRPW_DOWNLOAD_BASE_URL%/}"
    if [ -n "$download_base" ]; then
        download_file "$download_base/SHA256SUMS" "$destination"
        [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ] || die "downloaded SHA256SUMS is invalid"
        return
    fi
    id=""
    if [ "$FRPW_USE_GITHUB_API" = "1" ] && [ -n "$RELEASE_JSON" ]; then
        id="$(asset_id "SHA256SUMS")"
    fi
    case "$id" in
        '' | *[!0-9]*) id="" ;;
    esac
    api_base="${FRPW_GITHUB_API_URL%/}"
    if [ -n "$id" ] && download_file "$api_base/repos/$FRPW_REPO/releases/assets/$id" "$destination" && [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ]; then
        return
    fi
    [ -z "$id" ] || warn "GitHub API checksum download was invalid; trying public download URL"
    github_download_base="${FRPW_GITHUB_DOWNLOAD_URL%/}"
    download_file "$github_download_base/$FRPW_REPO/releases/download/$FRPW_VERSION/SHA256SUMS" "$destination"
    [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ] || die "downloaded SHA256SUMS is invalid"
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

verify_license() {
    [ -n "$FRPW_LICENSE" ] || die "this is a paid distribution: set FRPW_LICENSE to your license key, for example
  curl -fsSL <install.sh URL> | sudo FRPW_LICENSE=FRPW-xxx... sh -s -- server
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
    max_installs="$(cut -d"|" -f4 < "$TMP_LIC/payload")"
    log "license verified: $customer (expires $(date -d "@$expires" +%Y-%m-%d 2>/dev/null || date -r "$expires" +%Y-%m-%d 2>/dev/null), max installs: ${max_installs:-unlimited})"
    rm -rf "$TMP_LIC"
    trap - EXIT HUP INT TERM
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

verify_asset() {
    asset_name="$1"
    file="$2"
    sums="$3"
    expected="$(checksum_for_asset "$asset_name" "$sums")"
    [ -n "$expected" ] || die "SHA256SUMS has no valid entry for $asset_name"
    actual="$(sha256_file "$file")"
    if [ "$actual" != "$expected" ]; then
        die "checksum verification failed for $asset_name"
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
    die "cannot generate a secure JWT secret; install openssl or provide FRPW_JWT_SECRET"
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
        die "create a system user named $FRPW_SERVICE_USER or set FRPW_SERVICE_USER"
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
    else
        warn "systemd was not found; start manually with: $EXEC_START"
    fi
}

install_binary() {
    asset_name="$1"
    binary_path="$2"
    download_asset "$asset_name" "$TMP_DIR/$asset_name"
    verify_asset "$asset_name" "$TMP_DIR/$asset_name" "$TMP_DIR/SHA256SUMS"
    install -m 0755 "$TMP_DIR/$asset_name" "$binary_path"
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
            warn "optional release asset unavailable: $asset_name"
        fi
    done
    install -m 0644 "$TMP_DIR/SHA256SUMS" "$client_dir/SHA256SUMS"
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
    log "license key stored: $license_file"
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
    else
        log "preserving existing configuration: $CONFIG_FILE"
    fi

    download_client_catalog
    chown -R "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$INSTALL_DIR" "$DATA_DIR"
    [ -f "$CONFIG_FILE" ] && chown "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$CONFIG_FILE"
    EXEC_START="$INSTALL_DIR/frpw-server -config $CONFIG_FILE"
    write_systemd_unit

    log "FRPW server $FRPW_VERSION installed"
    log "user console: http://<server-ip>:${API_ADDR##*:}"
    log "admin console: http://<server-ip>:${API_ADDR##*:}$ADMIN_PATH"
    log "default admin: admin@example.com / admin12345 (change immediately)"
    log "default user: user@example.com / user12345 (change immediately)"
    warn "public HTTP port must be reachable on ${PUBLIC_HTTP_PORT}; Agent port must be reachable on ${AGENT_ADDR##*:}"
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

    [ -n "$AGENT_SERVER" ] || die "FRPW_SERVER is required, for example FRPW_SERVER=203.0.113.10:7000"
    [ -n "$AGENT_TOKEN_VALUE" ] || die "FRPW_AGENT_TOKEN is required"
    [ -n "$CONTROL_PLANE" ] || die "FRPW_CONTROL_PLANE is required, for example https://console.example.com"

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
    else
        log "preserving existing configuration: $CONFIG_FILE"
    fi

    chown -R "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$INSTALL_DIR" "$DATA_DIR"
    chown "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$CONFIG_FILE"
    EXEC_START="$INSTALL_DIR/frpw-agent -headless -config $CONFIG_FILE"
    write_systemd_unit
    log "FRPW Agent $FRPW_VERSION installed on node $NODE_ID"
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

    [ -n "$CONTROL_PLANE" ] || die "FRPW_CONTROL_PLANE is required"
    [ -n "$NODE_TOKEN_VALUE" ] || die "FRPW_NODE_TOKEN is required"

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
    else
        log "preserving existing configuration: $CONFIG_FILE"
    fi

    chown -R "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$INSTALL_DIR" "$DATA_DIR"
    chown "$FRPW_SERVICE_USER:$FRPW_SERVICE_USER" "$CONFIG_FILE"
    EXEC_START="$INSTALL_DIR/frpw-node -config $CONFIG_FILE"
    write_systemd_unit
    log "FRPW remote node $FRPW_VERSION installed"
}

main() {
    need_root
    [ "$(uname -s)" = "Linux" ] || die "install.sh supports Linux only"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
    case "$COMPONENT" in
        server) verify_license ;;
    esac
    if [ -n "$FRPW_LOCAL_DIR" ]; then
        log "installing from local release directory: $FRPW_LOCAL_DIR"
    else
        load_release
    fi
    download_checksums "$TMP_DIR/SHA256SUMS"

    case "$COMPONENT" in
        server) install_server ;;
        agent) install_agent ;;
        node) install_node ;;
        *) die "component must be server, agent, or node" ;;
    esac
}

main "$@"
