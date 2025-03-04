#!/usr/bin/env bash
# Hysteria 2 终极管理脚本 v5.0
# Author: Hysteria-Pro-Team
# GitHub: https://github.com/hysteria-pro/installer

# 常量定义
readonly HY_BIN="/usr/local/bin/hysteria"
readonly HY_DIR="/etc/hysteria"
readonly HY_SERVICE="/etc/systemd/system/hysteria-server.service"
readonly NGINX_CONF="/etc/nginx/sites-available/hysteria-proxy.conf"
readonly SCRIPT_NAME=$(basename "$0")
readonly GITHUB_CDN="https://cdn.jsdelivr.net/gh/apernet/hysteria@latest"
readonly BACKUP_MIRROR="https://gitlab.com/hysteria-mirror/hysteria/-/raw/main"

# 颜色定义
RED='\033[1;31m'; GREEN='\033[1;32m'
YELLOW='\033[1;33m'; BLUE='\033[1;36m'
PLAIN='\033[0m'; BOLD='\033[1m'

# 全局变量
rh_post=()
declare -A DEPS_MAP=(
    [curl]=""
    [jq]=""
    [openssl]="openssl"
    [qrencode]="qrencode"
    [nginx]="nginx"
)

log() {
    local level color prefix
    case $1 in
        INFO) color=$BLUE; prefix="[ℹ]" ;;
        PASS) color=$GREEN; prefix="[✓]" ;;
        WARN) color=$YELLOW; prefix="[⚠]" ;;
        FAIL) color=$RED; prefix="[✗]" ;;
        *) return ;;
    esac
    shift
    echo -e "${color}$(date +"%Y-%m-%d %T") ${prefix} $* ${PLAIN}"
}

init_check() {
    [[ $EUID -ne 0 ]] && { log FAIL "必须使用 ROOT 权限运行！"; exit 1; }
    [[ -L /bin/sh ]] && rm -f /bin/sh && ln -s /bin/bash /bin/sh
}

smart_install() {
    for pkg in "${!DEPS_MAP[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            log INFO "正在安装依赖: ${pkg}..."
            if [[ -n ${DEPS_MAP[$pkg]} ]]; then
                install_pkg "${DEPS_MAP[$pkg]}" || {
                    log WARN "自动安装 ${pkg} 失败，请手动安装"
                    return 1
                }
            fi
        fi
    done
}

install_pkg() {
    local pkg=$1
    if command -v apt &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt install -y "$pkg"
    elif command -v yum &>/dev/null; then
        yum install -y "$pkg"
    elif command -v dnf &>/dev/null; then
        dnf install -y "$pkg"
    else
        log WARN "未支持的包管理器，请手动安装: ${pkg}"
        return 1
    fi
}

download_with_retry() {
    local url=$1 attempts=3 timeout=30 retry_delay=5 temp_file
    temp_file=$(mktemp)
    
    for ((i=1; i<=attempts; i++)); do
        if curl -L -# \
            --connect-timeout "$timeout" \
            --retry 2 \
            --retry-delay "$retry_delay" \
            -o "$temp_file" \
            "$url"; then
            echo "$temp_file"
            return 0
        else
            log WARN "下载失败，尝试重试 (${i}/${attempts})..."
            sleep $((i*retry_delay))
        fi
    done
    rm -f "$temp_file"
    log FAIL "无法下载文件: $url"
    return 1
}

secure_install() {
    local temp_dir temp_file
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    log INFO "正在释放文件锁..."    
    systemctl stop hysteria-server 2>/dev/null
    pkill -9 hysteria
    sleep 2
    
    log INFO "检测处理器架构..."
    case $(uname -m) in
        x86_64) arch="amd64";;
        aarch64) arch="arm64";;
        armv7l) arch="arm";;
        *) log FAIL "不支持的架构: $(uname -m)"; exit 1 ;;
    esac

    log INFO "获取最新版本..."
    local version=$(curl -s "${BACKUP_MIRROR}/stable_version.txt")
    [[ -z $version ]] && version=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    
    log INFO "开始下载核心文件 (版本: ${version})..."
    local main_url="https://github.com/apernet/hysteria/releases/download/${version}/hysteria-linux-${arch}"
    local cdn_url="${GITHUB_CDN}/hysteria-linux-${arch}"
    local mirror_url="${BACKUP_MIRROR}/releases/download/${version}/hysteria-linux-${arch}"
    
    if ! temp_file=$(download_with_retry "$main_url") && \
       ! temp_file=$(download_with_retry "$cdn_url") && \
       ! temp_file=$(download_with_retry "$mirror_url"); then
        exit 1
    fi

    log INFO "执行安全检查..."
    if ! file "$temp_file" | grep -q "ELF"; then
        log FAIL "下载文件已损坏！"
        exit 1
    fi

    log INFO "安装到系统..."
    install -m 755 "$temp_file" "${HY_BIN}.new"
    mv -f "${HY_BIN}.new" "$HY_BIN"
    rm -f "$temp_file"
}

setup_server() {
    local ip port password masquerade cert_type
    
    log INFO "获取公网IP地址..."
    ip=$(curl -4sL https://ifconfig.io || curl -6sL https://ifconfig.io)
    [[ -z $ip ]] && { read -p "输入服务器IP: " ip || exit; }

    log INFO "生成安全密码..."
    password=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=')

    log INFO "配置监听端口..."
    while :; do
        read -p "输入端口号[默认: 随机]: " port
        port=${port:-$((RANDOM%55535+10000))}
        if ! ss -tuln | grep -q ":${port} "; then
            break
        fi
        log WARN "端口 ${port} 已被占用！"
    done

    log INFO "选择伪装类型:"
    select masquerade in "反向代理" "文件服务器" "自定义域名"; do
        case $masquerade in
            "反向代理") site="en.wikipedia.org"; break ;;
            "文件服务器") setup_nginx; site=$ip; break ;;
            "自定义域名") read -p "输入域名: " site; break ;;
            *) log WARN "无效选项";;
        esac
    done

    log INFO "选择证书类型:"
    select cert_type in "自动生成" "Let's Encrypt" "自定义证书"; do
        case $cert_type in
            "自动生成") generate_self_signed; break ;;
            "Let's Encrypt") setup_le_cert; break ;;
            "自定义证书") import_custom_cert; break ;;
            *) log WARN "无效选项";;
        esac
    done
}

start_service() {
    log INFO "配置系统服务..."
    cat > "$HY_SERVICE" <<EOF
[Unit]
Description=Hysteria 2 VPN Server
After=network.target

[Service]
ExecStart=${HY_BIN} server -c ${HY_DIR}/config.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-server
    [[ $? -eq 0 ]] && log PASS "服务启动成功" || log FAIL "服务启动失败"
}

main_menu() {
    while true; do
        clear
        echo -e "${BOLD}» Hysteria 2 管理菜单 «${PLAIN}"
        echo -e "${GREEN}1. 安装/重装"
        echo -e "${BLUE}2. 显示配置"
        echo -e "${YELLOW}3. 服务管理"
        echo -e "${RED}4. 完全卸载"
        echo -e "${PLAIN}0. 退出"
        echo -e "\n${BOLD}当前状态: ${PLAIN}$(systemctl is-active hysteria-server 2>/dev/null || echo '未安装')"

        read -p "请选择操作: " choice
        case $choice in
            1) full_install;;
            2) show_config;;
            3) service_menu;;
            4) uninstall;;
            0) exit 0;;
            *) log WARN "无效选项!"; sleep 1;;
        esac
    done
}

full_install() {
    {
        init_check
        smart_install
        secure_install
        setup_server
        start_service
    } 
}

uninstall() {
    log WARN "开始完全卸载..."
    systemctl stop hysteria-server
    rm -f "$HY_BIN" "$HY_SERVICE"
    rm -rf "$HY_DIR"
    systemctl daemon-reload
    log PASS "已彻底移除所有组件"
}

main_menu "$@"
