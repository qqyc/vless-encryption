#!/usr/bin/env bash

# Xray VLESS Encryption installer and manager
# shellcheck shell=bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.0.1"

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
XRAY_CONFIG_PATH="${XRAY_CONFIG_PATH:-${XRAY_CONFIG_DIR}/config.json}"
XRAY_SERVICE="${XRAY_SERVICE:-xray}"
XRAY_INSTALL_SCRIPT_URL="${XRAY_INSTALL_SCRIPT_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"

STATE_DIR="${VLESS_ENCRYPTION_STATE_DIR:-/var/lib/vless-encryption}"
CLIENT_ENCRYPTION_FILE="${STATE_DIR}/client-encryption"
SERVER_ADDRESS_FILE="${STATE_DIR}/server-address"
LEGACY_CLIENT_ENCRYPTION_FILE="${LEGACY_CLIENT_ENCRYPTION_FILE:-/root/xray_encryption_info.txt}"

IS_QUIET=false
ASSUME_YES=false
NO_GEODATA=false
ROTATE_KEYS=false
SERVER_ADDRESS=""
PACKAGE_MANAGER=""

VLESS_DECRYPTION=""
VLESS_ENCRYPTION=""
CURRENT_PORT=""
CURRENT_UUID=""
CURRENT_DECRYPTION=""
RESOLVED_ADDRESS=""

TEMP_FILES=()

C_RESET=$'\033[0m'
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    USE_COLOR=true
else
    USE_COLOR=false
fi

cleanup() {
    local file
    for file in "${TEMP_FILES[@]}"; do
        if [[ -e "$file" ]]; then
            rm -f -- "$file" || true
        fi
    done
}
trap cleanup EXIT

register_temp_file() {
    TEMP_FILES+=("$1")
}

print_color() {
    local color="$1"
    shift
    if [[ "$USE_COLOR" == true ]]; then
        printf '%b%s%b\n' "$color" "$*" "$C_RESET"
    else
        printf '%s\n' "$*"
    fi
}

info() {
    [[ "$IS_QUIET" == true ]] || print_color "$C_BLUE" "[i] $*" >&2
}

success() {
    [[ "$IS_QUIET" == true ]] || print_color "$C_GREEN" "[+] $*" >&2
}

warn() {
    print_color "$C_YELLOW" "[!] $*" >&2
}

error() {
    print_color "$C_RED" "[x] $*" >&2
}

die() {
    error "$*"
    exit 1
}

require_root() {
    [[ "$(id -u)" == "0" ]] || die "此操作必须由 root 用户执行。"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_package_manager() {
    if command_exists apt-get; then
        PACKAGE_MANAGER="apt-get"
    elif command_exists dnf; then
        PACKAGE_MANAGER="dnf"
    elif command_exists yum; then
        PACKAGE_MANAGER="yum"
    else
        die "仅支持使用 apt-get、dnf 或 yum 的 Linux 发行版。"
    fi
}

install_dependencies() {
    local missing=()
    local command_name

    for command_name in curl jq; do
        command_exists "$command_name" || missing+=("$command_name")
    done
    ((${#missing[@]} == 0)) && return 0

    detect_package_manager
    info "正在安装依赖：${missing[*]}"
    case "$PACKAGE_MANAGER" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq
            ;;
        dnf|yum)
            "$PACKAGE_MANAGER" install -y ca-certificates curl jq
            ;;
    esac

    for command_name in curl jq; do
        command_exists "$command_name" || die "依赖安装失败：${command_name}"
    done
}

preflight_mutation() {
    require_root
    command_exists systemctl || die "当前系统不使用 systemd，无法管理 Xray 服务。"
    install_dependencies
}

download_official_installer() {
    local destination="$1"

    if ! curl \
        --proto '=https' \
        --tlsv1.2 \
        --fail \
        --show-error \
        --silent \
        --location \
        --retry 3 \
        --connect-timeout 10 \
        --output "$destination" \
        "$XRAY_INSTALL_SCRIPT_URL"; then
        error "下载 Xray 官方安装脚本失败。"
        return 1
    fi

    if ! grep -q '^#!/usr/bin/env bash' "$destination" ||
       ! grep -q 'github.com/XTLS/Xray-install' "$destination"; then
        error "下载内容不像 XTLS/Xray-install 官方脚本，已拒绝执行。"
        return 1
    fi
}

run_official_installer() {
    local installer
    installer="$(mktemp)"
    register_temp_file "$installer"

    info "正在获取 Xray 官方安装器……"
    download_official_installer "$installer" || return 1
    info "正在运行 Xray 官方安装器……"

    if [[ "$IS_QUIET" == true ]]; then
        bash "$installer" "$@" >&2
    else
        bash "$installer" "$@"
    fi
}

xray_is_installed() {
    [[ -x "$XRAY_BIN" ]]
}

xray_supports_vless_encryption() {
    xray_is_installed && "$XRAY_BIN" help vlessenc >/dev/null 2>&1
}

require_xray() {
    xray_is_installed || die "Xray 尚未安装。请先运行 install 命令。"
}

require_vless_encryption_support() {
    xray_supports_vless_encryption || die "当前 Xray 不支持 vlessenc，请先更新 Xray。"
}

xray_version() {
    if ! xray_is_installed; then
        printf '%s\n' "未安装"
        return
    fi
    "$XRAY_BIN" version 2>/dev/null | awk 'NR == 1 { version = $2 } END { print version }'
}

is_valid_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535))
}

is_valid_uuid() {
    local uuid="${1:-}"
    [[ "$uuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
}

generate_uuid() {
    if xray_is_installed; then
        "$XRAY_BIN" uuid
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid
    elif command_exists uuidgen; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        die "无法生成 UUID。"
    fi
}

parse_vlessenc_output() {
    local output="$1"
    local line in_pq_section=false

    VLESS_DECRYPTION=""
    VLESS_ENCRYPTION=""

    while IFS= read -r line; do
        case "$line" in
            Authentication:\ ML-KEM-768*) in_pq_section=true; continue ;;
            Authentication:*) in_pq_section=false; continue ;;
        esac

        [[ "$in_pq_section" == true ]] || continue
        if [[ "$line" == *'"decryption"'* ]]; then
            VLESS_DECRYPTION="$(sed -n 's/.*"decryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$line")"
        elif [[ "$line" == *'"encryption"'* ]]; then
            VLESS_ENCRYPTION="$(sed -n 's/.*"encryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$line")"
        fi
    done <<<"$output"

    if [[ ! "$VLESS_DECRYPTION" =~ ^mlkem768x25519plus\.native\.[^[:space:]]+$ ]] ||
       [[ ! "$VLESS_ENCRYPTION" =~ ^mlkem768x25519plus\.native\.[^[:space:]]+$ ]]; then
        VLESS_DECRYPTION=""
        VLESS_ENCRYPTION=""
        return 1
    fi
}

generate_vlessenc_pair() {
    local output
    info "正在生成 ML-KEM-768 VLESS Encryption 密钥……"
    if ! output="$("$XRAY_BIN" vlessenc 2>&1)"; then
        error "xray vlessenc 执行失败：${output}"
        return 1
    fi
    if ! parse_vlessenc_output "$output"; then
        error "无法识别 xray vlessenc 的 ML-KEM-768 输出格式。"
        return 1
    fi
}

validate_server_address() {
    local address="${1:-}"
    local colon_chars label normalized
    local labels=()

    [[ -n "$address" ]] || return 1
    [[ ! "$address" =~ [[:space:]@/#?] ]] || return 1

    # These names are reserved for documentation. Accepting them makes a
    # copy-pasted example look valid while producing an unusable share link.
    normalized="${address,,}"
    case "$normalized" in
        example|*.example|example.com|*.example.com|example.net|*.example.net|example.org|*.example.org)
            return 1
            ;;
    esac

    if [[ "$address" == *:* ]]; then
        colon_chars="${address//[^:]/}"
        ((${#colon_chars} >= 2)) || return 1
        [[ "$address" =~ ^[[:xdigit:]:.]+$ ]]
        return
    fi

    if [[ "$address" =~ ^[0-9.]+$ ]]; then
        is_valid_ipv4 "$address"
        return
    fi

    ((${#address} <= 253)) || return 1
    [[ "$address" != .* && "$address" != *. && "$address" != *..* ]] || return 1
    IFS=. read -r -a labels <<<"$address"
    for label in "${labels[@]}"; do
        ((${#label} >= 1 && ${#label} <= 63)) || return 1
        [[ "$label" =~ ^[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?$ ]] || return 1
    done
}

strip_ipv6_brackets() {
    local address="$1"
    address="${address#[}"
    address="${address%]}"
    printf '%s\n' "$address"
}

is_valid_ipv4() {
    local ip="${1:-}"
    local a b c d extra octet
    IFS=. read -r a b c d extra <<<"$ip"
    [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1
    done
}

fetch_ip() {
    local family="$1"
    local url="$2"
    curl "$family" --fail --show-error --silent --max-time 5 "$url" 2>/dev/null |
        tr -d '[:space:]'
}

get_public_ipv4() {
    local source ip
    for source in https://api.ipify.org https://api-ipv4.ip.sb/ip https://ip.seeip.org; do
        ip="$(fetch_ip -4 "$source" || true)"
        if is_valid_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

get_public_ipv6() {
    local source ip
    for source in https://api64.ipify.org https://api-ipv6.ip.sb/ip; do
        ip="$(fetch_ip -6 "$source" || true)"
        if [[ "$ip" == *:* && "$ip" =~ ^[[:xdigit:]:.]+$ ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

resolve_server_address() {
    local requested="${1:-}"
    local saved=""

    if [[ -n "$requested" ]]; then
        requested="$(strip_ipv6_brackets "$requested")"
        validate_server_address "$requested" || return 1
        RESOLVED_ADDRESS="$requested"
        return 0
    fi

    if [[ -r "$SERVER_ADDRESS_FILE" ]]; then
        saved="$(tr -d '\r\n' <"$SERVER_ADDRESS_FILE")"
        if validate_server_address "$saved"; then
            RESOLVED_ADDRESS="$saved"
            return 0
        fi
    fi

    RESOLVED_ADDRESS="$(get_public_ipv4 || true)"
    [[ -n "$RESOLVED_ADDRESS" ]] || RESOLVED_ADDRESS="$(get_public_ipv6 || true)"
    [[ -n "$RESOLVED_ADDRESS" ]]
}

url_encode() {
    jq -rn --arg value "$1" '$value | @uri'
}

build_vless_url() {
    local address="$1"
    local port="$2"
    local uuid="$3"
    local encryption="$4"
    local name="${5:-$(hostname) VLESS-E}"
    local url_host="$address"

    [[ "$address" == *:* ]] && url_host="[${address}]"
    printf 'vless://%s@%s:%s?encryption=%s&flow=xtls-rprx-vision&type=tcp&security=none#%s\n' \
        "$uuid" \
        "$url_host" \
        "$port" \
        "$(url_encode "$encryption")" \
        "$(url_encode "$name")"
}

service_group() {
    local user group
    user="$(systemctl show --property=User --value "$XRAY_SERVICE" 2>/dev/null || true)"
    [[ -n "$user" ]] || user="root"
    group="$(id -gn "$user" 2>/dev/null || true)"
    [[ -n "$group" ]] || group="root"
    printf '%s\n' "$group"
}

render_config() {
    local destination="$1"
    local port="$2"
    local uuid="$3"
    local decryption="$4"

    jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg decryption "$decryption" \
        '{
            log: {loglevel: "warning"},
            inbounds: [{
                tag: "vless-encryption-in",
                listen: "::",
                port: $port,
                protocol: "vless",
                settings: {
                    users: [{id: $uuid, flow: "xtls-rprx-vision"}],
                    decryption: $decryption
                }
            }],
            outbounds: [{
                tag: "direct",
                protocol: "freedom"
            }]
        }' >"$destination"
}

validate_xray_config() {
    local config="$1"
    local output
    if ! output="$("$XRAY_BIN" run -test -format=json -config="$config" 2>&1)"; then
        error "Xray 拒绝了新配置，未写入系统。"
        printf '%s\n' "$output" >&2
        return 1
    fi
}

read_current_config() {
    [[ -r "$XRAY_CONFIG_PATH" ]] || return 1

    local values
    if ! values="$(jq -er '
        .inbounds as $all
        | (($all | map(select(.tag == "vless-encryption-in")) | .[0]) // $all[0]) as $in
        | [
            $in.port,
            ($in.settings.users[0].id // $in.settings.clients[0].id),
            $in.settings.decryption
          ]
        | @tsv
    ' "$XRAY_CONFIG_PATH" 2>/dev/null)"; then
        return 1
    fi

    IFS=$'\t' read -r CURRENT_PORT CURRENT_UUID CURRENT_DECRYPTION <<<"$values"
    is_valid_port "$CURRENT_PORT" && is_valid_uuid "$CURRENT_UUID" && [[ -n "$CURRENT_DECRYPTION" ]]
}

is_legacy_managed_config() {
    [[ -r "$XRAY_CONFIG_PATH" ]] || return 1
    jq -e '
        ((keys - ["inbounds", "log", "outbounds"]) | length) == 0 and
        (.inbounds | length) == 1 and
        (.outbounds | length) == 1 and
        .inbounds[0].protocol == "vless" and
        (.inbounds[0].settings.decryption | startswith("mlkem768x25519plus.")) and
        (.inbounds[0].settings.clients | type == "array") and
        .outbounds[0].protocol == "freedom"
    ' "$XRAY_CONFIG_PATH" >/dev/null 2>&1
}

is_current_managed_config() {
    [[ -r "$XRAY_CONFIG_PATH" ]] || return 1
    jq -e '
        ((keys - ["inbounds", "log", "outbounds"]) | length) == 0 and
        (.inbounds | length) == 1 and
        (.outbounds | length) == 1 and
        .inbounds[0].tag == "vless-encryption-in" and
        .inbounds[0].protocol == "vless" and
        (.inbounds[0].settings.decryption | startswith("mlkem768x25519plus.")) and
        (.inbounds[0].settings.users | type == "array") and
        .outbounds[0].protocol == "freedom"
    ' "$XRAY_CONFIG_PATH" >/dev/null 2>&1
}

is_script_managed_config() {
    is_current_managed_config || is_legacy_managed_config
}

load_client_encryption() {
    local value=""

    if [[ -r "$CLIENT_ENCRYPTION_FILE" ]]; then
        value="$(tr -d '\r\n' <"$CLIENT_ENCRYPTION_FILE")"
    elif [[ -r "$LEGACY_CLIENT_ENCRYPTION_FILE" ]]; then
        value="$(tr -d '\r\n' <"$LEGACY_CLIENT_ENCRYPTION_FILE")"
        [[ "$value" =~ ^mlkem768x25519plus\.native\.[^[:space:]]+$ ]] || return 1
        warn "检测到旧版客户端密钥文件，将迁移到 ${CLIENT_ENCRYPTION_FILE}。"
        install -d -o root -g root -m 0700 "$STATE_DIR" || return 1
        printf '%s\n' "$value" |
            install -o root -g root -m 0600 /dev/stdin "$CLIENT_ENCRYPTION_FILE" || return 1
    fi

    [[ "$value" =~ ^mlkem768x25519plus\.native\.[^[:space:]]+$ ]] || return 1
    VLESS_ENCRYPTION="$value"
}

restart_xray() {
    info "正在重启 Xray……"
    if ! systemctl restart "$XRAY_SERVICE"; then
        error "Xray 服务重启失败。"
        return 1
    fi

    local _
    for _ in 1 2 3 4 5; do
        systemctl is-active --quiet "$XRAY_SERVICE" && return 0
        sleep 1
    done

    error "Xray 服务未进入运行状态。"
    journalctl -u "$XRAY_SERVICE" -n 20 --no-pager >&2 || true
    return 1
}

apply_configuration() {
    local port="$1"
    local uuid="$2"
    local decryption="$3"
    local encryption="$4"
    local config_temp secret_temp backup_path="" group

    install -d -o root -g root -m 0755 "$XRAY_CONFIG_DIR" || return 1
    install -d -o root -g root -m 0700 "$STATE_DIR" || return 1

    config_temp="$(mktemp "${XRAY_CONFIG_PATH}.tmp.XXXXXX")" || return 1
    register_temp_file "$config_temp"
    secret_temp="$(mktemp "${STATE_DIR}/client-encryption.tmp.XXXXXX")" || return 1
    register_temp_file "$secret_temp"

    render_config "$config_temp" "$port" "$uuid" "$decryption" || return 1
    printf '%s\n' "$encryption" >"$secret_temp" || return 1
    validate_xray_config "$config_temp" || return 1

    group="$(service_group)"
    chmod 0640 "$config_temp" || return 1
    chown root:"$group" "$config_temp" || return 1
    chmod 0600 "$secret_temp" || return 1
    chown root:root "$secret_temp" || return 1

    if [[ -e "$XRAY_CONFIG_PATH" ]]; then
        backup_path="${XRAY_CONFIG_PATH}.bak.$(date -u +%Y%m%dT%H%M%SZ).$$"
        cp -p -- "$XRAY_CONFIG_PATH" "$backup_path" || return 1
        chown root:root "$backup_path" || return 1
        chmod 0600 "$backup_path" || return 1
        info "原配置已备份到 ${backup_path}"
    fi

    local old_secret=""
    if [[ -e "$CLIENT_ENCRYPTION_FILE" ]]; then
        old_secret="$(mktemp)" || return 1
        register_temp_file "$old_secret"
        cp -p -- "$CLIENT_ENCRYPTION_FILE" "$old_secret" || return 1
    fi

    # Both temporary files live on the same filesystems as their destinations,
    # so rename(2) makes each replacement atomic.
    mv -f -- "$secret_temp" "$CLIENT_ENCRYPTION_FILE" || return 1
    if ! mv -f -- "$config_temp" "$XRAY_CONFIG_PATH"; then
        error "替换配置文件失败，正在恢复客户端密钥。"
        if [[ -n "$old_secret" ]]; then
            cp -p -- "$old_secret" "$CLIENT_ENCRYPTION_FILE" || true
        else
            rm -f -- "$CLIENT_ENCRYPTION_FILE"
        fi
        return 1
    fi

    if restart_xray; then
        [[ -n "$old_secret" ]] && rm -f -- "$old_secret"
        success "配置已通过校验并生效。"
        return 0
    fi

    error "新配置启动失败，正在回滚。"
    if [[ -n "$backup_path" ]]; then
        cp -p -- "$backup_path" "$XRAY_CONFIG_PATH"
        chown root:"$group" "$XRAY_CONFIG_PATH"
        chmod 0640 "$XRAY_CONFIG_PATH"
    else
        rm -f -- "$XRAY_CONFIG_PATH"
    fi
    if [[ -n "$old_secret" ]]; then
        cp -p -- "$old_secret" "$CLIENT_ENCRYPTION_FILE"
        rm -f -- "$old_secret"
    else
        rm -f -- "$CLIENT_ENCRYPTION_FILE"
    fi
    restart_xray || error "回滚后 Xray 仍无法启动，请检查日志。"
    return 1
}

save_server_address() {
    local address="${1:-}"
    [[ -n "$address" ]] || return 0
    address="$(strip_ipv6_brackets "$address")"
    validate_server_address "$address" || die "服务器地址无效：${address}"
    install -d -o root -g root -m 0700 "$STATE_DIR"
    printf '%s\n' "$address" | install -o root -g root -m 0600 /dev/stdin "$SERVER_ADDRESS_FILE"
}

show_client_link() {
    local requested_address="${1:-}"
    require_xray
    read_current_config || die "无法从 ${XRAY_CONFIG_PATH} 读取 VLESS Encryption 配置。"
    load_client_encryption || die "找不到匹配的客户端 encryption 密钥，请运行 config --rotate-keys 修复。"
    resolve_server_address "$requested_address" || die "无法确定服务器公网地址，请使用 --address 指定 IP 或域名。"

    local link
    link="$(build_vless_url "$RESOLVED_ADDRESS" "$CURRENT_PORT" "$CURRENT_UUID" "$VLESS_ENCRYPTION")"
    if [[ "$IS_QUIET" == true ]]; then
        printf '%s\n' "$link"
        return
    fi

    printf '\n'
    print_color "$C_CYAN" "--- VLESS Encryption 客户端信息 ---"
    printf '地址: %s\n端口: %s\nUUID: %s\n' "$RESOLVED_ADDRESS" "$CURRENT_PORT" "$CURRENT_UUID"
    printf '模式: ML-KEM-768 + native + 0-RTT + Vision\n\n'
    print_color "$C_GREEN" "$link"
    printf '\n'
}

confirm() {
    local prompt="$1"
    local default="${2:-no}"
    local answer

    [[ "$ASSUME_YES" == true ]] && return 0
    if [[ "$default" == yes ]]; then
        read -r -p "${prompt} [Y/n] " answer
        [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
    else
        read -r -p "${prompt} [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]]
    fi
}

cmd_install_values() {
    local port="$1"
    local uuid="$2"
    local link_address

    is_valid_port "$port" || die "端口无效：${port}"
    [[ -n "$uuid" ]] || uuid="$(generate_uuid)"
    is_valid_uuid "$uuid" || die "UUID 格式无效：${uuid}"
    resolve_server_address "$SERVER_ADDRESS" ||
        die "无法确定服务器公网地址，请使用 --address 指定 IP 或域名。"
    link_address="$RESOLVED_ADDRESS"

    if xray_is_installed && [[ -e "$XRAY_CONFIG_PATH" ]]; then
        confirm "Xray 已安装。继续会替换主配置（旧配置会备份），是否继续？" no || {
            info "操作已取消。"
            return 0
        }
    fi

    local installer_args=(install)
    [[ "$NO_GEODATA" == true ]] && installer_args+=(--without-geodata)
    run_official_installer "${installer_args[@]}" || die "Xray 安装失败。"
    require_vless_encryption_support

    generate_vlessenc_pair || die "生成 VLESS Encryption 配置失败。"
    apply_configuration "$port" "$uuid" "$VLESS_DECRYPTION" "$VLESS_ENCRYPTION" || die "配置写入失败。"
    save_server_address "$SERVER_ADDRESS"
    show_client_link "$link_address"
}

cmd_install() {
    local port="443"
    local uuid=""

    preflight_mutation
    while (($#)); do
        case "$1" in
            --port)
                (($# >= 2)) || die "--port 缺少参数。"
                port="$2"
                shift 2
                ;;
            --uuid)
                (($# >= 2)) || die "--uuid 缺少参数。"
                uuid="$2"
                shift 2
                ;;
            --quiet|-q) IS_QUIET=true; shift ;;
            --yes|-y) ASSUME_YES=true; shift ;;
            --no-geodata) NO_GEODATA=true; shift ;;
            --address)
                (($# >= 2)) || die "--address 缺少参数。"
                SERVER_ADDRESS="$2"
                shift 2
                ;;
            *) die "install 的未知参数：$1" ;;
        esac
    done
    cmd_install_values "$port" "$uuid"
}

cmd_update() {
    preflight_mutation
    require_xray

    while (($#)); do
        case "$1" in
            --quiet|-q) IS_QUIET=true; shift ;;
            --no-geodata) NO_GEODATA=true; shift ;;
            *) die "update 的未知参数：$1" ;;
        esac
    done

    local installer_args=(install)
    [[ "$NO_GEODATA" == true ]] && installer_args+=(--without-geodata)
    run_official_installer "${installer_args[@]}" || die "Xray 更新失败。"
    require_vless_encryption_support

    if is_legacy_managed_config; then
        warn "检测到旧版 clients 配置，正在迁移到当前 Xray 的 users 格式。"
        read_current_config || die "无法读取旧版配置。"
        load_client_encryption || die "无法读取旧版客户端密钥。"
        apply_configuration "$CURRENT_PORT" "$CURRENT_UUID" "$CURRENT_DECRYPTION" "$VLESS_ENCRYPTION" ||
            die "旧配置迁移失败。"
    else
        validate_xray_config "$XRAY_CONFIG_PATH" || die "升级后的 Xray 不接受当前配置。"
        restart_xray || die "Xray 更新后启动失败。"
    fi
    success "Xray 已更新到 $(xray_version)。"
}

cmd_config_values() {
    local port="$1"
    local uuid="$2"
    local link_address

    require_xray
    require_vless_encryption_support
    is_script_managed_config ||
        die "当前配置不是本脚本管理的单入站配置，为避免覆盖自定义内容，已拒绝修改。"
    read_current_config || die "无法读取当前 VLESS Encryption 配置。"

    [[ -n "$port" ]] || port="$CURRENT_PORT"
    [[ -n "$uuid" ]] || uuid="$CURRENT_UUID"
    is_valid_port "$port" || die "端口无效：${port}"
    is_valid_uuid "$uuid" || die "UUID 格式无效：${uuid}"
    resolve_server_address "$SERVER_ADDRESS" ||
        die "无法确定服务器公网地址，请使用 --address 指定 IP 或域名。"
    link_address="$RESOLVED_ADDRESS"

    if [[ "$ROTATE_KEYS" == true ]] || ! load_client_encryption; then
        generate_vlessenc_pair || die "生成 VLESS Encryption 配置失败。"
    else
        VLESS_DECRYPTION="$CURRENT_DECRYPTION"
    fi

    apply_configuration "$port" "$uuid" "$VLESS_DECRYPTION" "$VLESS_ENCRYPTION" || die "修改配置失败。"
    save_server_address "$SERVER_ADDRESS"
    show_client_link "$link_address"
}

cmd_config() {
    local port=""
    local uuid=""

    preflight_mutation
    while (($#)); do
        case "$1" in
            --port)
                (($# >= 2)) || die "--port 缺少参数。"
                port="$2"
                shift 2
                ;;
            --uuid)
                (($# >= 2)) || die "--uuid 缺少参数。"
                uuid="$2"
                shift 2
                ;;
            --address)
                (($# >= 2)) || die "--address 缺少参数。"
                SERVER_ADDRESS="$2"
                shift 2
                ;;
            --rotate-keys) ROTATE_KEYS=true; shift ;;
            --quiet|-q) IS_QUIET=true; shift ;;
            *) die "config 的未知参数：$1" ;;
        esac
    done
    cmd_config_values "$port" "$uuid"
}

cmd_link() {
    require_root
    install_dependencies
    while (($#)); do
        case "$1" in
            --address)
                (($# >= 2)) || die "--address 缺少参数。"
                SERVER_ADDRESS="$2"
                shift 2
                ;;
            --quiet|-q) IS_QUIET=true; shift ;;
            *) die "link 的未知参数：$1" ;;
        esac
    done
    show_client_link "$SERVER_ADDRESS"
}

cmd_restart() {
    preflight_mutation
    require_xray
    restart_xray || die "Xray 重启失败。"
    success "Xray 已重启。"
}

cmd_logs() {
    require_root
    command_exists journalctl || die "系统中没有 journalctl。"
    require_xray
    local status=0
    journalctl -u "$XRAY_SERVICE" -f --no-pager || status=$?
    ((status == 0 || status == 130)) || return "$status"
}

cmd_status() {
    local version state port="未知"
    version="$(xray_version)"
    if xray_is_installed && command_exists systemctl && systemctl is-active --quiet "$XRAY_SERVICE"; then
        state="运行中"
    elif xray_is_installed; then
        state="未运行"
    else
        state="未安装"
    fi
    if command_exists jq && read_current_config; then
        port="$CURRENT_PORT"
    fi

    printf 'Xray 版本: %s\n服务状态: %s\n监听端口: %s\nVLESS Encryption: %s\n' \
        "$version" "$state" "$port" \
        "$(xray_supports_vless_encryption && printf '支持' || printf '不支持')"
}

cmd_uninstall() {
    preflight_mutation
    require_xray

    while (($#)); do
        case "$1" in
            --yes|-y) ASSUME_YES=true; shift ;;
            *) die "uninstall 的未知参数：$1" ;;
        esac
    done

    confirm "这会卸载 Xray 并删除主配置，是否继续？" no || {
        info "操作已取消。"
        return 0
    }
    run_official_installer remove --purge || die "Xray 卸载失败。"
    rm -f -- "$CLIENT_ENCRYPTION_FILE" "$SERVER_ADDRESS_FILE"
    rmdir -- "$STATE_DIR" 2>/dev/null || true
    rm -f -- /root/xray_vless_encryption_link.txt "$LEGACY_CLIENT_ENCRYPTION_FILE"
    success "Xray、主配置与本脚本保存的客户端信息已删除。"
}

prompt_port() {
    local current="${1:-443}"
    local value
    while true; do
        read -r -p "端口 [${current}]: " value
        value="${value:-$current}"
        if is_valid_port "$value"; then
            printf '%s\n' "$value"
            return
        fi
        error "请输入 1-65535 之间的端口。"
    done
}

prompt_uuid() {
    local current="${1:-}"
    local prompt value
    if [[ -n "$current" ]]; then
        prompt="UUID [${current}]: "
    else
        prompt="UUID [回车自动生成]: "
    fi
    while true; do
        read -r -p "$prompt" value
        value="${value:-$current}"
        [[ -n "$value" ]] || value="$(generate_uuid)"
        if is_valid_uuid "$value"; then
            printf '%s\n' "$value"
            return
        fi
        error "UUID 格式无效。"
    done
}

pause_menu() {
    printf '\n'
    read -r -n 1 -s -p "按任意键返回主菜单……"
    printf '\n'
}

interactive_install() {
    local port uuid
    port="$(prompt_port 443)"
    uuid="$(prompt_uuid)"
    cmd_install_values "$port" "$uuid"
}

interactive_config() {
    local port uuid
    require_xray
    read_current_config || die "无法读取当前配置。"
    port="$(prompt_port "$CURRENT_PORT")"
    uuid="$(prompt_uuid "$CURRENT_UUID")"
    if confirm "是否同时轮换 VLESS Encryption 密钥？现有客户端将失效。" no; then
        ROTATE_KEYS=true
    fi
    cmd_config_values "$port" "$uuid"
}

main_menu() {
    preflight_mutation
    while true; do
        clear || true
        print_color "$C_CYAN" "Xray VLESS Encryption 管理脚本 ${SCRIPT_VERSION}"
        printf '\n'
        cmd_status
        printf '\n'
        print_color "$C_GREEN" "1. 安装/重装"
        print_color "$C_GREEN" "2. 更新 Xray（并迁移旧配置）"
        print_color "$C_GREEN" "3. 修改端口或 UUID"
        print_color "$C_GREEN" "4. 查看客户端链接"
        print_color "$C_GREEN" "5. 重启 Xray"
        print_color "$C_GREEN" "6. 查看实时日志"
        print_color "$C_RED" "7. 卸载"
        printf '0. 退出\n\n'

        local choice should_pause=true
        read -r -p "请选择 [0-7]: " choice
        case "$choice" in
            1) interactive_install ;;
            2) cmd_update ;;
            3) interactive_config ;;
            4) show_client_link ;;
            5) cmd_restart ;;
            6) cmd_logs; should_pause=false ;;
            7) cmd_uninstall ;;
            0) return ;;
            *) error "无效选项。" ;;
        esac
        [[ "$should_pause" == true ]] && pause_menu
    done
}

show_help() {
    cat <<EOF
Xray VLESS Encryption 安装管理脚本 ${SCRIPT_VERSION}

用法:
  $0                         打开交互式菜单
  $0 install [选项]          安装或重装
  $0 update [选项]           更新 Xray，并迁移旧版 clients 配置
  $0 config [选项]           修改端口、UUID 或轮换密钥
  $0 link [选项]             输出客户端分享链接
  $0 status                  查看状态
  $0 restart                 重启服务
  $0 logs                    查看实时日志
  $0 uninstall [--yes]       卸载并清理配置

install 选项:
  --port <端口>              默认 443
  --uuid <UUID>              默认自动生成
  --address <IP或域名>       仅覆盖客户端链接地址；默认自动检测公网 IP
  --no-geodata               不安装 GeoIP/GeoSite
  --yes, -y                  不询问覆盖确认
  --quiet, -q                标准输出只保留客户端链接

config 选项:
  --port <端口>              留空则保持不变
  --uuid <UUID>              留空则保持不变
  --address <IP或域名>       仅更新客户端链接地址，不配置 TLS/SNI
  --rotate-keys              轮换加密密钥（现有客户端会失效）

示例:
  $0 install --port 443 --yes
  $0 install --port 8443 --uuid d0f6a483-51b3-44eb-94b6-1f5fc9272c81 --quiet
  $0 config --port 2053
  $0 link --quiet
EOF
}

main() {
    local command="${1:-menu}"
    (($# == 0)) || shift

    case "$command" in
        menu) main_menu ;;
        install) cmd_install "$@" ;;
        update) cmd_update "$@" ;;
        config) cmd_config "$@" ;;
        link) cmd_link "$@" ;;
        status) cmd_status "$@" ;;
        restart) cmd_restart "$@" ;;
        logs|log) cmd_logs "$@" ;;
        uninstall|remove) cmd_uninstall "$@" ;;
        help|-h|--help) show_help ;;
        version|-v|--version) printf '%s\n' "$SCRIPT_VERSION" ;;
        *) die "未知命令：${command}。使用 --help 查看帮助。" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
