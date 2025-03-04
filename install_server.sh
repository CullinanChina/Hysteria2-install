#!/usr/bin/env bash
# Hysteria 2 安装管理器 (协议混淆+流量统计)
# 更新日期：2025-02-25

set -euo pipefail

# 基础配置
VERSION="v2.2.2"
CONFIG_DIR="/etc/hysteria"
LOG_FILE="/var/log/hysteria.log"
STATS_FILE="/etc/hysteria/stats.json"

# 颜色定义
RED='\033[31m'    GREEN='\033[32m'
YELLOW='\033[33m' CYAN='\033[36m'
RESET='\033[0m'

# 依赖检查
check_deps() {
    local deps=(curl jq qrencode openssl iptables)
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v $dep &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        apt-get update
        apt-get install -y "${missing[@]}"
    fi
}

# 日志系统
log() {
    echo -e "[$(date '+%Y-%m-%d %T')] $1" | tee -a $LOG_FILE
}

# 颜色输出
color_echo() {
    echo -e "${1}${2}${RESET}"
}

# 错误处理
fatal() {
    log "[FATAL] $1"
    color_echo $RED "错误: $1" >&2
    exit 1
}

# 系统检测
detect_system() {
    case $(uname -m) in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) ARCH="unknown" ;;
    esac

    OS=$(grep -Ei '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
}

# 流量统计
init_stats() {
    [ -f "$STATS_FILE" ] || echo '{"total":{}, "daily":{}}' > "$STATS_FILE"
}

update_stats() {
    local up=$1 down=$2
    local today=$(date +%F)
    
    jq --arg today "$today" \
       --argjson up "$up" \
       --argjson down "$down" \
       '.total.up += $up | .total.down += $down | 
        .daily[$today].up = (.daily[$today].up // 0) + $up |
        .daily[$today].down = (.daily[$today].down // 0) + $down' \
       "$STATS_FILE" > tmp_stats && mv tmp_stats "$STATS_FILE"
}

show_stats() {
    [ -f "$STATS_FILE" ] || {
        color_echo $YELLOW "尚未生成统计信息"
        return
    }

    local total_up=$(jq '.total.up // 0' "$STATS_FILE")
    local total_down=$(jq '.total.down // 0' "$STATS_FILE")
    
    echo -e "${CYAN}>> 流量统计 <<${RESET}"
    echo -e "总上传: $(numfmt --to=iec $total_up)"
    echo -e "总下载: $(numfmt --to=iec $total_down)"
    
    echo -e "\n${CYAN}>> 最近7天统计 <<${RESET}"
    jq -r '.daily | to_entries[-7:] | reverse[] | 
        "\(.key): ↑\(.value.up|tobytes) ↓\(.value.down|tobytes)"' "$STATS_FILE"
}

# 协议混淆配置
configure_obfs() {
    echo -e "${YELLOW}选择协议混淆方式:${RESET}"
    select mode in "无" "HTTP伪装" "随机填充"; do
        case $mode in
            "HTTP伪装")
                OBFSPASS=$(openssl rand -hex 8)
                OBFSCONF="
obfs:
  type: salamander
  salamander:
    password: \"$OBFSPASS\""
                break ;;
            "随机填充")
                OBFSCONF="
obfs:
  type: random-padding
  random-padding:
    padding-up: 1500
    padding-down: 1500"
                break ;;
            *) OBFSCONF="" ; break ;;
        esac
    done
}

# 核心安装
install_core() {
    detect_system
    check_deps

    local BIN_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH}"
    curl -Lo /usr/local/bin/hysteria "$BIN_URL"
    chmod +x /usr/local/bin/hysteria
}

# 生成配置
generate_config() {
    local PASS=$(openssl rand -hex 8)
    mkdir -p $CONFIG_DIR

    cat > $CONFIG_DIR/config.yaml <<EOF
listen: :8443
tls:
  cert: $CONFIG_DIR/cert.pem
  key: $CONFIG_DIR/key.pem
auth:
  type: password
  password: $PASS
$OBFSCONF
masquerade:
  type: reverse_proxy
  proxy:
    url: https://connect.rom.miui.com
    rewriteHost: true
EOF

    # 生成客户端配置
    IP=$(curl -4s ip.gs || curl -6s ip.gs)
    mkdir -p /root/hy
    cat > /root/hy/client.yaml <<EOF
server: $IP:8443
auth: $PASS
tls:
  insecure: true
socks5:
  listen: 127.0.0.1:1080
transport:
  udp:
    hopInterval: 30s
EOF

    qrencode -t ANSIUTF8 -o /root/hy/qr.txt "hysteria2://$PASS@$IP:8443/?insecure=1#Hy2-Node"
}

# 服务管理
setup_service() {
    cat > /etc/systemd/system/hy-server.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/hysteria server --config $CONFIG_DIR/config.yaml
Restart=always
Environment="HYSTERIA_LOG_LEVEL=info"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

install() {
    color_echo $CYAN "\n>> 开始安装 Hysteria 2 <<"
    
    install_core
    configure_obfs
    generate_config
    setup_service
    
    color_echo $GREEN "\n安装完成!"
    echo -e "配置文件: ${YELLOW}/root/hy/client.yaml${RESET}"
    echo -e "快速连接: ${YELLOW}$(cat /root/hy/qr.txt)${RESET}"
}

uninstall() {
    systemctl stop hy-server 2>/dev/null || true
    rm -rf /usr/local/bin/hysteria $CONFIG_DIR /root/hy
    color_echo $GREEN "卸载完成"
}

manage() {
    case $1 in
        start)   systemctl start hy-server ;;
        stop)    systemctl stop hy-server ;;
        restart) systemctl restart hy-server ;;
        status)  systemctl status hy-server ;;
        *) fatal "未知操作: $1" ;;
    esac
}

# 主菜单
show_menu() {
    echo -e "\n${CYAN}Hysteria 2 管理系统${RESET}"
    echo "--------------------------------"
    echo "1) 全新安装"
    echo "2) 删除卸载"
    echo "3) 服务管理 (启动/停止/状态)"
    echo "4) 查看统计"
    echo "5) 显示配置"
    echo "0) 退出脚本"
    echo "--------------------------------"

    read -p "请选择操作: " choice
    case $choice in
        1) install ;;
        2) uninstall ;;
        3) 
            select action in start stop restart status; do
                manage $action
                break
            done ;;
        4) show_stats ;;
        5) [ -f /root/hy/client.yaml ] && cat /root/hy/client.yaml ;;
        0) exit 0 ;;
        *) color_echo $RED "无效选择" ;;
    esac
}

# 初始化
init_stats
check_deps

# 参数处理
case $1 in
    install) install ;;
    remove) uninstall ;;
    *) show_menu ;;
esac
