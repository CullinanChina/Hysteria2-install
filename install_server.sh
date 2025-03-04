#!/usr/bin/env bash
# Hysteria 2 一键安装管理脚本
# Version: 2.2.2
# Author: Hysteria-Enhanced-Team
# License: MIT

# 配置常量
HYSTERIA_BIN="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
SERVICE_DIR="/etc/systemd/system"
SCRIPT_NAME=$(basename "$0")

# 颜色定义
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# 环境变量
OS="$(uname -s)"
ARCH="$(uname -m)"
IP_API="https://api.ip.sb/geoip"

# 日志函数
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %T")
    case $level in
        "INFO") echo -e "${BLUE}${timestamp} [INFO]${PLAIN} ${message}" ;;
        "WARN") echo -e "${YELLOW}${timestamp} [WARN]${PLAIN} ${message}" ;;
        "ERROR") echo -e "${RED}${timestamp} [ERROR]${PLAIN} ${message}" ;;
        "SUCCESS") echo -e "${GREEN}${timestamp} [SUCCESS]${PLAIN} ${message}" ;;
    esac
}

# 检查权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "请使用root权限运行此脚本"
        exit 1
    fi
}

# 依赖管理
install_deps() {
    local deps=(curl wget jq openssl qrencode iptables-persistent netfilter-persistent)
    local pkg_managers=(
        "apt -y install"
        "yum -y install"
        "dnf -y install"
        "zypper -n install"
        "pacman -Syu --noconfirm"
    )
    
    for manager in "${pkg_managers[@]}"; do
        cmd=$(echo "$manager" | awk '{print $1}')
        if command -v "$cmd" &> /dev/null; then
            for pkg in "${deps[@]}"; do
                if ! command -v "$pkg" &> /dev/null; then
                    log "INFO" "正在安装依赖：${pkg}..."
                    $manager "$pkg" &> /dev/null || {
                        log "ERROR" "无法安装依赖：${pkg}"
                        exit 1
                    }
                fi
            done
            return 0
        fi
    done

    log "ERROR" "未找到合适的包管理器"
    exit 1
}

# 获取公网IP
get_ip() {
    IP=$(curl -4 -s https://api.ip.sb/geoip | jq -r '.ip')
    [ -z "$IP" ] && IP=$(curl -6 -s https://api.ip.sb/geoip | jq -r '.ip')
}

# 证书管理
manage_cert() {
    case $1 in
        "self-signed")
            openssl ecparam -genkey -name prime256v1 -out $CONFIG_DIR/server.key
            openssl req -new -x509 -days 365 -key $CONFIG_DIR/server.key \
                -out $CONFIG_DIR/server.crt -subj "/CN=www.bing.com"
            ;;
        "acme")
            # ACME申请逻辑（此处需补充完整）
            ;;
        "custom")
            read -p "证书路径: " cert_path
            read -p "私钥路径: " key_path
            cp "$cert_path" $CONFIG_DIR/server.crt
            cp "$key_path" $CONFIG_DIR/server.key
            ;;
    esac
    chmod 600 $CONFIG_DIR/server.*
}

# 服务管理
service_ctl() {
    systemctl $1 hysteria-server.service &> /dev/null
    [ $? -eq 0 ] && log "SUCCESS" "服务操作成功：$1" || log "ERROR" "服务操作失败"
}

# 端口检查
check_port() {
    ss -tunlp | grep -q ":$1 " && return 1 || return 0
}

# 配置生成
generate_config() {
    cat > $CONFIG_DIR/config.yaml <<EOF
listen: :$port
tls:
  cert: $CONFIG_DIR/server.crt
  key: $CONFIG_DIR/server.key

auth:
  type: password
  password: $password

masquerade:
  type: proxy
  proxy:
    url: https://$masquerade_site
    rewriteHost: true
EOF
}

# 安装主程序
install_hysteria() {
    log "INFO" "正在获取最新版本..."
    LATEST_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r '.tag_name')
    [ -z "$LATEST_VER" ] && { log "ERROR" "无法获取最新版本"; exit 1; }

    ARCH_MAP=(
        "x86_64:amd64"
        "aarch64:arm64"
        "armv7l:arm"
        "i386:386"
    )
    for pair in "${ARCH_MAP[@]}"; do
        if [ "$ARCH" = "${pair%%:*}" ]; then
            HY_ARCH="${pair#*:}"
            break
        fi
    done

    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/$LATEST_VER/hysteria-linux-$HY_ARCH"
    if ! curl -L -o $HYSTERIA_BIN "$DOWNLOAD_URL"; then
        log "ERROR" "文件下载失败"
        exit 1
    fi
    chmod +x $HYSTERIA_BIN
}

# 用户交互菜单
show_menu() {
    clear
    echo -e "${BOLD}Hysteria 2 专业管理脚本${PLAIN}"
    echo -e "${GREEN}1. 全新安装"
    echo -e "${YELLOW}2. 管理服务"
    echo -e "${BLUE}3. 显示配置"
    echo -e "${RED}4. 完全卸载"
    echo -e "${PLAIN}0. 退出脚本"
    read -p "请输入选项: " choice
}

# 主安装流程
main_install() {
    check_root
    install_deps
    install_hysteria

    # 用户交互配置
    read -p "选择证书类型 [1]自签/[2]ACME/[3]自定义 (默认1): " cert_type
    case ${cert_type:-1} in
        1) manage_cert self-signed ;;
        2) manage_cert acme ;;
        3) manage_cert custom ;;
    esac
    
    # 端口配置
    while true; do
        read -p "输入监听端口 (默认随机): " port
        port=${port:-$(shuf -i 10000-65535 -n 1)}
        check_port $port && break || log "WARN" "端口已被占用"
    done

    # 密码生成
    password=$(openssl rand -base64 12)
    log "INFO" "生成随机密码：${password}"

    # 伪装网站
    read -p "输入伪装网站 (默认en.snu.ac.kr): " masquerade_site
    masquerade_site=${masquerade_site:-en.snu.ac.kr}

    generate_config
    
    # 服务文件生成
    cat > $SERVICE_DIR/hysteria-server.service <<EOF
[Unit]
Description=Hysteria 2 Server Service
After=network.target

[Service]
User=root
ExecStart=$HYSTERIA_BIN server -c $CONFIG_DIR/config.yaml
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria-server.service --now
}

# 主逻辑
case $1 in
    install) main_install ;;
    *)
        while true; do
            show_menu
            case $choice in
                1) main_install ;;
                2) 
                    echo -e "${GREEN}1. 启动服务"
                    echo -e "${YELLOW}2. 停止服务"
                    echo -e "${RED}3. 重启服务"
                    read -p "选择操作: " service_op
                    case $service_op in
                        1) service_ctl start ;;
                        2) service_ctl stop ;;
                        3) service_ctl restart ;;
                    esac
                    ;;
                3) 
                    jq -nc --arg pass "$password" --arg ip "$IP" --arg port "$port" \
                        '{server: $ip, port: $port, password: $pass}' | \
                        qrencode -t utf8
                    ;;
                4) 
                    systemctl stop hysteria-server.service
                    rm -rf $HYSTERIA_BIN $CONFIG_DIR $SERVICE_DIR/hysteria-server.service
                    ;;
                0) exit 0 ;;
            esac
            read -n 1 -s -r -p "按任意键继续..."
        done
        ;;
esac
