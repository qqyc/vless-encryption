#!/bin/bash

# VLESS Encryption 一键安装管理脚本
# 版本: V1.6.0 (Bug修正 + 安全加固)
# 更新日志 (V1.6.0):
# - [严重] 移除 set -e，改用显式错误处理，修复交互模式下意外退出
# - [严重] 重写 vlessenc 输出解析逻辑，增加 jq 解析 + 正则回退双保险
# - [安全] 配置文件权限收紧至 600（仅 root 可读写）
# - [安全] 敏感信息文件 (encryption_info, link) 权限收紧至 600
# - [功能] 新增 UUID 格式校验
# - [功能] 修改配置前自动备份
# - [功能] 安装完成后提示防火墙放行
# - [健壮] hostname URL 编码
# - [健壮] 重启后轮询等待（最多 5 秒）
# - [健壮] run_install 中 exit 改为 return，避免菜单模式异常退出
# - [兼容] grep 使用 ERE（-E）提高可移植性
# 固定配置: native + 0-RTT + ML-KEM-768 + xtls-rprx-vision

# 不使用 set -e，所有错误通过显式检查处理

# --- 全局变量 ---
SCRIPT_VERSION="V1.6.0"
xray_config_path="/usr/local/etc/xray/config.json"
xray_binary_path="/usr/local/bin/xray"
xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

xray_status_info=""
is_quiet=false
PKG_MANAGER=""

# --- 颜色定义 ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_PURPLE='\033[0;35m'
C_CYAN='\033[0;36m'

# --- 基础函数 ---
if [ -t 1 ]; then
    use_color=true
else
    use_color=false
fi

cecho() {
    local color_name="$1"
    local message="$2"
    if [ "$use_color" = true ] && [ -n "$color_name" ]; then
        echo -e "${color_name}${message}${C_RESET}"
    else
        echo "$message"
    fi
}

error() {
    cecho "$C_RED" "[✖] $1" >&2
}

info() {
    if [ "$is_quiet" = false ]; then
        cecho "$C_BLUE" "[!] $1" >&2
    fi
}

success() {
    if [ "$is_quiet" = false ]; then
        cecho "$C_GREEN" "[✔] $1" >&2
    fi
}

# --- 工具函数 ---

url_encode() {
    local string="$1"
    # 使用 jq 进行 URL 编码（已确认 jq 是依赖项）
    printf '%s' "$string" | jq -sRr @uri 2>/dev/null || printf '%s' "$string" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g'
}

# --- 核心功能函数 ---

get_public_ip_v4() {
    local ip
    local sources=(
        "https://api-ipv4.ip.sb/ip"
        "https://api.ipify.org"
        "https://ip.seeip.org"
    )
    for source in "${sources[@]}"; do
        ip=$(curl -4s --max-time 5 "$source" 2>/dev/null) || true
        if echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            echo "$ip"
            return
        fi
    done
    echo ""
}

get_public_ip_v6() {
    local ip
    local sources=(
        "https://api-ipv6.ip.sb/ip"
        "https://api64.ipify.org"
    )
    for source in "${sources[@]}"; do
        ip=$(curl -6s --max-time 5 "$source" 2>/dev/null) || true
        if echo "$ip" | grep -q ':'; then
            echo "$ip"
            return
        fi
    done
    echo ""
}

execute_official_script() {
    local args="$1"
    local script_content
    info "正在下载官方安装脚本..."
    script_content=$(curl -sL --max-time 60 "$xray_install_script_url") || true

    if [[ -z "$script_content" ]]; then
        error "下载 Xray 官方安装脚本失败！请检查网络连接。"
        return 1
    fi

    # 安全增强：检查脚本基本特征（至少包含 shebang 和关键函数）
    if [[ ! "$script_content" =~ ^#! ]] || [[ ! "$script_content" =~ "install" ]]; then
        error "下载的安装脚本内容异常，已中止执行。"
        return 1
    fi

    info "正在执行官方安装脚本 ( $args )..."
    # shellcheck disable=SC2086
    echo "$script_content" | bash -s -- $args
    return $?
}

check_xray_version() {
    if [ ! -f "$xray_binary_path" ]; then
        return 1
    fi
    if ! "$xray_binary_path" help 2>/dev/null | grep -q "vlessenc"; then
        return 1
    fi
    return 0
}

check_os_and_dependencies() {
    info "正在检查操作系统和依赖..."
    if command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    else
        error "错误: 未知的包管理器, 此脚本仅支持 apt, dnf, yum."
        exit 1
    fi

    local missing_deps=()
    command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        info "检测到缺失的依赖 (${missing_deps[*]})，正在尝试自动安装..."
        case "$PKG_MANAGER" in
            apt)
                apt-get update >/dev/null 2>&1
                apt-get install -y "${missing_deps[@]}" >/dev/null 2>&1
                ;;
            dnf | yum)
                "$PKG_MANAGER" install -y "${missing_deps[@]}" >/dev/null 2>&1
                ;;
        esac

        for dep in "${missing_deps[@]}"; do
            if ! command -v "$dep" >/dev/null 2>&1; then
                error "依赖 ($dep) 自动安装失败。请手动安装后重试。"
                exit 1
            fi
        done
        success "依赖已成功安装。"
    fi
}

pre_check() {
    if [ "$(id -u)" != "0" ]; then
        error "错误: 您必须以root用户身份运行此脚本"
        exit 1
    fi
    check_os_and_dependencies
}

check_xray_status() {
    if [ ! -f "$xray_binary_path" ]; then
        xray_status_info="$(cecho "$C_YELLOW" "Xray 状态: 未安装")"
        return
    fi

    local xray_version
    xray_version=$("$xray_binary_path" version 2>/dev/null | head -n 1 | awk '{print $2}') || true
    [ -z "$xray_version" ] && xray_version="未知"

    local service_status
    if systemctl is-active --quiet xray 2>/dev/null; then
        service_status="$(cecho "$C_GREEN" "运行中")"
    else
        service_status="$(cecho "$C_RED" "未运行")"
    fi

    local encryption_support
    if check_xray_version; then
        encryption_support=" | $(cecho "$C_GREEN" "支持 VLESS Encryption")"
    else
        encryption_support=" | $(cecho "$C_RED" "不支持 VLESS Encryption")"
    fi

    xray_status_info="Xray 状态: $(cecho "$C_GREEN" "已安装") | ${service_status} | 版本: $(cecho "$C_CYAN" "$xray_version")${encryption_support}"
}

is_valid_port() {
    local port="$1"
    # 使用 ERE 替代 BRE 的 \+，提高可移植性
    if echo "$port" | grep -qE '^[0-9]+$' && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

is_valid_uuid() {
    local uuid="$1"
    if echo "$uuid" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
        return 0
    fi
    return 1
}

generate_uuid() {
    if [ -f "$xray_binary_path" ] && [ -x "$xray_binary_path" ]; then
        "$xray_binary_path" uuid
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

generate_vless_encryption_config() {
    info "正在生成 VLESS Encryption 配置 (native + 0-RTT + ML-KEM-768)..."

    local vlessenc_output
    vlessenc_output=$("$xray_binary_path" vlessenc 2>/dev/null) || true
    if [ -z "$vlessenc_output" ]; then
        error "生成 VLESS Encryption 配置失败 (xray vlessenc 无输出)"
        return 1
    fi

    local decryption_config="" encryption_config=""

    # 方法1: 尝试提取 ML-KEM-768 区段的 JSON 块并用 jq 解析
    local json_block
    json_block=$(echo "$vlessenc_output" | \
        awk '/ML-KEM-768/{found=1} found && /\{/{p=1} p{print} p && /\}/{p=0; exit}') || true

    if [ -n "$json_block" ]; then
        decryption_config=$(echo "$json_block" | jq -r '.decryption // empty' 2>/dev/null) || true
        encryption_config=$(echo "$json_block" | jq -r '.encryption // empty' 2>/dev/null) || true
    fi

    # 方法2: 回退到字符串匹配（处理非标准 JSON 输出的情况）
    if [ -z "$decryption_config" ] || [ -z "$encryption_config" ]; then
        info "JSON 解析未成功，尝试回退解析..."
        local mlkem_section
        mlkem_section=$(echo "$vlessenc_output" | sed -n '/ML-KEM-768/,/^$/p') || true

        if [ -n "$mlkem_section" ]; then
            decryption_config=$(echo "$mlkem_section" | sed -n 's/.*"decryption": *"\([^"]*\)".*/\1/p' | head -1)
            # encryption 可能跨行，合并后提取
            encryption_config=$(echo "$mlkem_section" | tr -d '\n ' | sed -n 's/.*"encryption": *"\([^"]*\)".*/\1/p' | head -1)
        fi
    fi

    if [ -z "$decryption_config" ] || [ -z "$encryption_config" ]; then
        error "无法解析 VLESS Encryption 配置。请确保 Xray 版本支持此功能。"
        error "--- xray vlessenc 原始输出 (调试信息) ---"
        echo "$vlessenc_output" >&2
        error "--- 输出结束 ---"
        return 1
    fi

    success "VLESS Encryption 配置生成成功。"
    echo "${decryption_config}|${encryption_config}"
}


install_xray() {
    if [ -f "$xray_binary_path" ]; then
        if ! check_xray_version; then
            info "检测到已安装的 Xray 版本不支持 VLESS Encryption，需要更新。"
        else
            info "检测到 Xray 已安装。继续操作将覆盖现有配置。"
        fi
        echo -n "是否继续？[y/N]: "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            info "操作已取消。"
            return
        fi
    fi

    info "开始配置 VLESS Encryption (native + 0-RTT + ML-KEM-768)..."
    local port uuid

    while true; do
        echo -n "请输入端口 [1-65535] (默认: 443): "
        read -r port
        [ -z "$port" ] && port=443
        if is_valid_port "$port"; then
            # 新增：端口冲突检测
            if command -v ss >/dev/null 2>&1; then
                if ss -tulpan | grep -q ":$port "; then
                    error "端口 $port 已经被系统中的其他程序占用，请更换端口！"
                    continue
                fi
            fi
            break
        else
            error "端口无效，请输入一个1-65535之间的数字。"
        fi
    done

    echo -n "请输入UUID (留空将默认生成随机UUID): "
    read -r uuid
    if [ -n "$uuid" ]; then
        if ! is_valid_uuid "$uuid"; then
            error "UUID 格式无效，应为 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx 格式。"
            return 1
        fi
    else
        uuid=$(generate_uuid)
        info "已为您生成随机UUID: ${uuid}"
    fi

    run_install "$port" "$uuid"
}

update_xray() {
    if [ ! -f "$xray_binary_path" ]; then
        error "错误: Xray 未安装，无法执行更新。请先选择安装选项。"
        return
    fi

    info "正在检查最新版本..."
    local current_version latest_version
    current_version=$("$xray_binary_path" version | head -n 1 | awk '{print $2}' | sed 's/v//') || true
    latest_version=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name // empty' | sed 's/v//' 2>/dev/null) || true

    if [ -z "$latest_version" ]; then
        error "获取最新版本号失败，请检查网络或稍后再试。"
        return
    fi

    info "当前版本: ${current_version}，最新版本: ${latest_version}"

    if [ "$current_version" = "$latest_version" ] && check_xray_version; then
        success "您的 Xray 已是最新版本且支持 VLESS Encryption，无需更新。"
        return
    fi

    info "开始更新..."
    if ! execute_official_script "install"; then
        error "Xray 核心更新失败！"
        return
    fi

    info "正在更新 GeoIP 和 GeoSite 数据文件..."
    execute_official_script "install-geodata" || true

    if ! restart_xray; then return; fi
    success "Xray 更新成功！"
}

restart_xray() {
    if [ ! -f "$xray_binary_path" ]; then
        error "错误: Xray 未安装，无法重启。"
        return 1
    fi

    if [ -f "$xray_config_path" ]; then
        info "正在验证配置文件..."
        # 修正：使用 su 替代 sudo，因为并非所有极简系统都有 sudo
        local run_user
        run_user=$(id -nu nobody 2>/dev/null || echo "root")
        
        if command -v su >/dev/null 2>&1 && [ "$run_user" != "root" ]; then
            if ! su -s /bin/bash "$run_user" -c "\"$xray_binary_path\" run -test -config \"$xray_config_path\"" >/dev/null 2>&1; then
                error "配置文件验证失败！"
                "$xray_binary_path" run -test -config "$xray_config_path" 2>&1 | head -5 >&2
                return 1
            fi
        else
            # 如果没有 su 或者找不到 nobody 用户，直接用 root 测
            if ! "$xray_binary_path" run -test -config "$xray_config_path" >/dev/null 2>&1; then
                error "配置文件验证失败！"
                "$xray_binary_path" run -test -config "$xray_config_path" 2>&1 | head -5 >&2
                return 1
            fi
        fi
    fi

    info "正在重启 Xray 服务..."
    if ! systemctl restart xray; then
        error "错误: Xray 服务重启失败。"
        return 1
    fi

    local max_wait=5
    local i=0
    while [ $i -lt $max_wait ]; do
        sleep 1
        if systemctl is-active --quiet xray; then
            success "Xray 服务已成功重启！"
            return 0
        fi
        i=$((i + 1))
    done

    error "错误: Xray 服务启动超时 (${max_wait}s)，查看日志："
    journalctl -u xray --no-pager -n 10 >&2
    return 1
}

uninstall_xray() {
    if [ ! -f "$xray_binary_path" ]; then
        error "错误: Xray 未安装，无需卸载。"
        return
    fi

    echo -n "您确定要卸载 Xray 吗？这将删除所有相关文件。[Y/n]: "
    read -r confirm
    if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
        info "卸载操作已取消。"
        return
    fi

    info "正在卸载 Xray..."
    if execute_official_script "remove"; then
        # 新增：彻底清理残留文件
        rm -rf /usr/local/etc/xray
        rm -rf /var/log/xray
        rm -f ~/xray_vless_encryption_link.txt ~/xray_encryption_info.txt
        success "Xray 已成功彻底卸载。"
    else
        error "Xray 卸载失败！"
        return 1
    fi
}

view_xray_log() {
    if [ ! -f "$xray_binary_path" ]; then
        error "错误: Xray 未安装，无法查看日志。"
        return
    fi

    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

modify_config() {
    if [ ! -f "$xray_config_path" ]; then
        error "错误: 配置文件不存在，无法修改配置。请先安装。"
        return
    fi

    info "读取当前配置..."
    local current_port current_uuid
    current_port=$(jq -r '.inbounds[0].port // empty' "$xray_config_path") || true
    current_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$xray_config_path") || true

    if [ -z "$current_port" ] || [ -z "$current_uuid" ]; then
        error "无法读取当前配置，配置文件可能已损坏。"
        return 1
    fi

    info "请输入新配置，直接回车则保留当前值。"
    local port uuid

    while true; do
        echo -n "端口 (当前: ${current_port}): "
        read -r port
        [ -z "$port" ] && port=$current_port
        if is_valid_port "$port"; then
            break
        else
            error "端口无效，请输入一个1-65535之间的数字。"
        fi
    done

    echo -n "UUID (当前: ${current_uuid}): "
    read -r uuid
    if [ -n "$uuid" ] && [ "$uuid" != "$current_uuid" ]; then
        if ! is_valid_uuid "$uuid"; then
            error "UUID 格式无效，应为 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx 格式。"
            return 1
        fi
    fi
    [ -z "$uuid" ] && uuid=$current_uuid

    local encryption_info
    encryption_info=$(generate_vless_encryption_config) || true
    if [ -z "$encryption_info" ]; then
        return 1
    fi

    local decryption_config encryption_config
    decryption_config=$(echo "$encryption_info" | cut -d'|' -f1)
    encryption_config=$(echo "$encryption_info" | cut -d'|' -f2)

    # 备份当前配置
    cp "$xray_config_path" "${xray_config_path}.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份当前配置。"

    write_config "$port" "$uuid" "$decryption_config" "$encryption_config"

    if ! restart_xray; then
        error "重启失败，正在回滚配置..."
        local latest_backup
        latest_backup=$(ls -t "${xray_config_path}".bak.* 2>/dev/null | head -1)
        if [ -n "$latest_backup" ]; then
            cp "$latest_backup" "$xray_config_path"
            chmod 600 "$xray_config_path"
            systemctl restart xray 2>/dev/null || true
            info "已回滚到之前的配置。"
        fi
        return 1
    fi

    success "配置修改成功！"
    view_subscription_info
}

view_subscription_info() {
    if [ ! -f "$xray_config_path" ]; then
        error "错误: 配置文件不存在, 请先安装。"
        return
    fi

    local ip4 ip6
    ip4=$(get_public_ip_v4)
    ip6=$(get_public_ip_v6)

    if [ -z "$ip4" ] && [ -z "$ip6" ]; then
        error "无法获取任何公网 IP 地址 (IPv4 或 IPv6)，无法生成订阅链接。"
        return 1
    fi

    local display_ip=${ip4:-$ip6}

    local uuid port encryption
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$xray_config_path") || true
    port=$(jq -r '.inbounds[0].port // empty' "$xray_config_path") || true

    if [ -z "$uuid" ] || [ -z "$port" ]; then
        error "配置文件读取失败或格式异常。"
        return 1
    fi

    if [ ! -f ~/xray_encryption_info.txt ]; then
        error "缺少客户端 encryption 信息文件，请重新安装以修复。"
        return
    fi
    encryption=$(cat ~/xray_encryption_info.txt 2>/dev/null)

    if [ -z "$encryption" ]; then
        error "缺少客户端 encryption 信息，可能是旧版配置，请重新安装以修复。"
        return
    fi

    local link_name_encoded
    link_name_encoded=$(url_encode "$(hostname) VLESS-E")

    local address_for_url=$display_ip
    if [[ $display_ip == *":"* ]]; then
        address_for_url="[${display_ip}]"
    fi

    local vless_url="vless://${uuid}@${address_for_url}:${port}?encryption=${encryption}&flow=xtls-rprx-vision&type=tcp&security=none#${link_name_encoded}"

    if [ "$is_quiet" = true ]; then
        echo "${vless_url}"
    else
        (umask 077; echo "${vless_url}" > ~/xray_vless_encryption_link.txt)
        echo "----------------------------------------------------------------"
        cecho "$C_CYAN" " --- Xray VLESS-Encryption 订阅信息 --- "

        echo " 名称: $(cecho "$C_GREEN" "$(hostname) VLESS-E")"
        if [ -n "$ip4" ]; then
            echo " 地址(IPv4): $(cecho "$C_GREEN" "$ip4")"
        fi
        if [ -n "$ip6" ]; then
            echo " 地址(IPv6): $(cecho "$C_GREEN" "$ip6")"
        fi
        echo " 端口: $(cecho "$C_GREEN" "$port")"
        echo " UUID: $(cecho "$C_GREEN" "$uuid")"

        echo " 协议: $(cecho "$C_YELLOW" "VLESS Encryption (native + 0-RTT + ML-KEM-768)")"
        echo " 流控: $(cecho "$C_YELLOW" "xtls-rprx-vision")"
        echo "----------------------------------------------------------------"
        cecho "$C_GREEN" " 订阅链接 (已保存到 ~/xray_vless_encryption_link.txt): "
        echo
        cecho "$C_GREEN" "$vless_url"
        echo "----------------------------------------------------------------"
    fi
}

write_config() {
    local port="$1" uuid="$2" decryption_config="$3" encryption_config="$4"

    (umask 077; echo "$encryption_config" > ~/xray_encryption_info.txt)

    local config_dir
    config_dir=$(dirname "$xray_config_path")
    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir"
    fi

    jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg decryption "$decryption_config" \
        --arg flow "xtls-rprx-vision" \
    '{
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "listen": "::",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": $uuid, "flow": $flow}],
                "decryption": $decryption
            }
        }],
        "outbounds": [{
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4v6"
            }
        }]
    }' > "$xray_config_path"

    # ========== 修正的权限设置 ==========
    # Xray 服务以 nobody 用户运行，需要读取配置文件
    # 方案：640 root:<nobody的组>，兼顾安全与可用性
    local xray_group
    xray_group=$(id -gn nobody 2>/dev/null || echo "nogroup")
    chmod 640 "$xray_config_path"
    chown "root:${xray_group}" "$xray_config_path"
}

run_install() {
    local port="$1" uuid="$2"

    info "正在下载并安装 Xray 核心..."
    if ! execute_official_script "install"; then
        error "Xray 核心安装失败！请检查网络连接。"
        return 1
    fi

    info "正在安装/更新 GeoIP 和 GeoSite 数据文件..."
    execute_official_script "install-geodata" || true

    if ! check_xray_version; then
        error "安装的 Xray 版本不支持 VLESS Encryption！请检查安装的版本。"
        return 1
    fi

    local encryption_info
    encryption_info=$(generate_vless_encryption_config) || true
    if [ -z "$encryption_info" ]; then
        error "生成 VLESS Encryption 配置失败！"
        return 1
    fi

    local decryption_config encryption_config
    decryption_config=$(echo "$encryption_info" | cut -d'|' -f1)
    encryption_config=$(echo "$encryption_info" | cut -d'|' -f2)

    info "正在写入 Xray 配置文件..."
    write_config "$port" "$uuid" "$decryption_config" "$encryption_config"

    if ! restart_xray; then return 1; fi

    success "Xray VLESS Encryption 安装/配置成功！"
    echo ""
    cecho "$C_YELLOW" "⚠ 提示: 请确认防火墙已放行端口 ${port}："
    cecho "$C_YELLOW" "  • ufw:       ufw allow ${port}/tcp"
    cecho "$C_YELLOW" "  • firewalld: firewall-cmd --permanent --add-port=${port}/tcp && firewall-cmd --reload"
    cecho "$C_YELLOW" "  • iptables:  iptables -I INPUT -p tcp --dport ${port} -j ACCEPT"
    echo ""

    view_subscription_info
}

press_any_key_to_continue() {
    echo ""
    cecho "$C_YELLOW" "按任意键返回主菜单..."
    read -r -n 1 -s || true
}

main_menu() {
    while true; do
        clear
        cecho "$C_CYAN" "--- Xray VLESS-Encryption 一键安装管理脚本 v${SCRIPT_VERSION} ---"
        echo
        check_xray_status
        echo "  ${xray_status_info}"
        cecho "$C_GREEN"  "─────────────────────────────────────────────────────"

        cecho "$C_GREEN" "  1. 安装/重装 Xray (VLESS-Encryption)"
        cecho "$C_GREEN" "  2. 更新 Xray"
        cecho "$C_GREEN" "  3. 重启 Xray"
        cecho "$C_GREEN" "  4. 卸载 Xray"
        cecho "$C_GREEN" "  5. 查看 Xray 日志"
        cecho "$C_GREEN" "  6. 修改节点配置"
        cecho "$C_GREEN" "  7. 查看订阅信息"

        cecho "$C_GREEN"  "─────────────────────────────────────────────────────"
        cecho "$C_RED"    "  0. 退出脚本"
        cecho "$C_GREEN"  "─────────────────────────────────────────────────────"
        cecho "$C_YELLOW" "  注意: 使用 native + 0-RTT + ML-KEM-768 + xtls-rprx-vision"
        cecho "$C_GREEN"  "─────────────────────────────────────────────────────"
        echo -n "  请输入选项 [0-7]: "
        read -r choice

        local needs_pause=true
        case $choice in
            1) install_xray ;;
            2) update_xray ;;
            3) restart_xray ;;
            4) uninstall_xray ;;
            5) view_xray_log; needs_pause=false ;;
            6) modify_config ;;
            7) view_subscription_info ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项，请输入 0-7 之间的数字。" ;;
        esac

        if [ "$needs_pause" = true ]; then
            press_any_key_to_continue
        fi
    done
}

main() {
    pre_check
    if [ $# -gt 0 ] && [ "$1" = "install" ]; then
        shift
        local port="" uuid=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --port)
                    if [ -z "${2:-}" ]; then error "--port 需要一个参数"; exit 1; fi
                    port="$2"; shift 2 ;;
                --uuid)
                    if [ -z "${2:-}" ]; then error "--uuid 需要一个参数"; exit 1; fi
                    uuid="$2"; shift 2 ;;
                --quiet|-q) is_quiet=true; shift ;;
                *) error "未知参数: $1"; show_help; exit 1 ;;
            esac
        done

        [ -z "$port" ] && port=443
        if [ -z "$uuid" ]; then
            uuid=$(generate_uuid)
        fi

        if ! is_valid_port "$port"; then
            error "端口参数无效 ($port)。请输入 1-65535 之间的数字。"
            exit 1
        fi

        if [ -n "$uuid" ] && ! is_valid_uuid "$uuid"; then
            error "UUID 参数格式无效 ($uuid)。"
            exit 1
        fi

        run_install "$port" "$uuid"
    else
        main_menu
    fi
}

show_help() {
    echo "Xray VLESS-Encryption 一键安装管理脚本 $SCRIPT_VERSION"
    echo
    echo "用法:"
    echo "   $0                 # 交互式菜单"
    echo "   $0 install [选项]  # 静默安装"
    echo
    echo "安装选项:"
    echo "   --port <端口>      # 监听端口 (默认: 443)"
    echo "   --uuid <UUID>      # 用户UUID (默认: 自动生成)"
    echo "   --quiet, -q        # 静默模式，只输出订阅链接"
    echo
    echo "固定配置 (最优设置):"
    echo "   协议: VLESS Encryption"
    echo "   外观: native (原生外观，性能最佳，支持XTLS完全穿透)"
    echo "   RTT:  0rtt (密钥复用600秒，性能优化)"
    echo "   认证: mlkem768 (ML-KEM-768 抗量子加密)"
    echo "   流控: xtls-rprx-vision (推荐的流控方式)"
    echo
    echo "示例:"
    echo "   $0 install --port 8443"
    echo "   $0 install --quiet --uuid 12345678-1234-1234-1234-123456789abc"
    echo
}

# --- 脚本入口 ---

if [ $# -gt 0 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
    show_help
    exit 0
fi

main "$@"
