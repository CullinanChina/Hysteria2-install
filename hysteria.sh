#!/usr/bin/env bash
# Hysteria 2 Pro 一键安装管理脚本 (修复版)
# Version: 3.1.1
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

# 全局变量
IP=""
PORT=""
PASSWORD=""
MASQUERADE_SITE="en.snu.ac.kr"

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
            log "WARN" "ACME功能暂未实现，使用自签名证书"
            manage_cert self-signed
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
    case $1 in
        "start"|"stop"|"restart"|"status")
            systemctl $1 hysteria-server.service &> /dev/null
            [ $? -eq 0 ] && log "SUCCESS" "服务操作成功：$1" || log "ERROR" "服务操作失败"
            ;;
        *) log "ERROR" "无效的服务操作命令" ;;
    esac
}

# 端口检查
check_port() {
    ss -tunlp | grep -q ":$1 " && return 1 || return 0
}

# 配置生成
generate_config() {
    cat > $CONFIG_DIR/config.yaml <<EOF
listen: :$PORT
tls:
  cert: $CONFIG_DIR/server.crt
  key: $CONFIG_DIR/server.key

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://$MASQUERADE_SITE
    rewriteHost: true
EOF
}

# 安装主程序
install_hysteria() {
    log "INFO" "正在获取最新版本..."
    LATEST_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r '.tag_name')
    [ -z "$LATEST_VER" ] && { log "ERROR" "无法获取最新版本"; exit 1; }

    declare -A ARCH_MAP=(
        ["x86_64"]="amd64" 
        ["aarch64"]="arm64"
        ["armv7l"]="arm"
        ["i386"]="386"
    )

    HY_ARCH=${ARCH_MAP["$ARCH"]}
    [ -z "$HY_ARCH" ] && { log "ERROR" "不支持的架构: $ARCH"; exit 1; }

    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/$LATEST_VER/hysteria-linux-$HY_ARCH"
    log "INFO" "下载链接: $DOWNLOAD_URL"
    
    if ! curl -L -o $HYSTERIA_BIN "$DOWNLOAD_URL"; then
        log "ERROR" "文件下载失败"
        exit 1
    fi
    chmod +x $HYSTERIA_BIN
}

# 主安装流程
main_install() {
    check_root
    get_ip
    install_deps
    install_hysteria

    mkdir -p $CONFIG_DIR

    # 证书类型选择
    echo -e "${BOLD}选择证书类型："
    echo -e "1) 自签名证书（默认）"
    echo -e "2) ACME证书（需要域名）"
    echo -e "3) 自定义证书"
    read -p "请输入选项 [1-3]: " cert_type

    case ${cert_type:-1} in
        1) manage_cert self-signed ;;
        2) manage_cert acme ;;
        3) manage_cert custom ;;
        *) log "ERROR" "无效选项，使用默认证书"; manage_cert self-signed ;;
    esac
    
    # 端口配置
    while true; do
        read -p "输入监听端口 (默认随机): " port
        PORT=${port:-$(shuf -i 10000-65535 -n 1)}
        check_port $PORT && break || log "WARN" "端口 $PORT 已被占用"
    done

    # 密码生成
    PASSWORD=$(openssl rand -base64 12)
    log "INFO" "生成随机密码：${PASSWORD}"

    # 伪装网站
    read -p "输入伪装网站 (默认en.snu.ac.kr): " masquerade_site
    MASQUERADE_SITE=${masquerade_site:-en.snu.ac.kr}

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
    log "SUCCESS" "服务安装完成！"
}

# 显示配置信息
show_config() {
    [ ! -f $CONFIG_DIR/config.yaml ] && {
        log "ERROR" "未找到配置文件"
        return
    }
    
    echo -e "${BOLD}当前配置信息："
    echo -e "${GREEN}服务器IP: ${IP}"
    echo -e "监听端口: ${PORT}"
    echo -e "连接密码: ${PASSWORD}"
    echo -e "伪装网站: ${MASQUERADE_SITE}${PLAIN}"
}

# 完全卸载
full_uninstall() {
    systemctl stop hysteria-server.service 2>/dev/null
    rm -f $HYSTERIA_BIN
    rm -rf $CONFIG_DIR
    rm -f $SERVICE_DIR/hysteria-server.service
    systemctl daemon-reload
    log "SUCCESS" "已完全卸载 Hysteria 服务"
}

# 用户交互菜单
show_menu() {
    clear
    echo -e "${BOLD}▛▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▜"
    echo -e "▌ Hysteria 2 专业管理脚本 ▐"
    echo -e "▙▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▟${PLAIN}"
    echo -e "${GREEN}1. 全新安装"
    echo -e "${YELLOW}2. 服务管理"
    echo -e "${BLUE}3. 显示配置"
    echo -e "${RED}4. 完全卸载"
    echo -e "${PLAIN}0. 退出脚本"
    echo -e "${BOLD}服务状态: $(systemctl is-active hysteria-server.service 2>/dev/null || echo '未安装')${PLAIN}"
}

# 主逻辑
case $1 in
    install) main_install ;;
    *)
        while true; do
            show_menu
            read -p "请输入选项: " choice
            case $choice in
                1) main_install ;;
                2) 
                    echo -e "${GREEN}1. 启动服务"
                    echo -e "${YELLOW}2. 停止服务"
                    echo -e "${BLUE}3. 重启服务"
                    echo -e "${RED}4. 服务状态"
                    read -p "选择操作: " service_op
                    case $service_op in
                        1) service_ctl start ;;
                        2) service_ctl stop ;;
                        3) service_ctl restart ;;
                        4) service_ctl status ;;
                        *) log "ERROR" "无效选项" ;;
                    esac
                    ;;
                3) show_config ;;
                4) full_uninstall ;;
                0) exit 0 ;;
                *) log "ERROR" "无效选项" ;;
            esac
            read -n 1 -s -r -p "按任意键继续..."
        done
        ;;
esac
