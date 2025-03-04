#!/usr/bin/env bash
# Hysteria 2 一键管理脚本
# 增强功能：协议混淆 + 流量统计
# 版本：v2.2.0
# 更新日期：2025-02-25

export LANG=en_US.UTF-8
VERSION="v2.2.0"
LOG_FILE="/var/log/hysteria.log"
STATS_FILE="/etc/hysteria/stats.data"

RED='\033[31m'    GREEN='\033[32m'
YELLOW='\033[33m' CYAN='\033[36m'
PLAIN='\033[0m'

# 初始化目录
init_dirs() {
    mkdir -p /etc/hysteria /root/hy/stats
}

# 日志记录
log() {
    echo -e "$(date '+%Y-%m-%d %T') - $1" | tee -a $LOG_FILE
}

color_echo() {
    echo -e "${1}${2}${PLAIN}"
}

fatal() {
    log "[FATAL] $1"
    color_echo $RED "$1" && exit 1
}

# 系统检测
detect_system() {
    grep -Eqi "ubuntu|debian" /etc/os-release && echo "debian" && return
    grep -Eqi "centos|redhat" /etc/os-release && echo "centos" && return
    grep -Eqi "almalinux|rocky" /etc/os-release && echo "centos" && return
    echo "unknown"
}

# 流量统计
init_stats() {
    [[ ! -f $STATS_FILE ]] && echo '{"total_up":0,"total_down":0,"daily":{}}' > $STATS_FILE
}

update_stats() {
    local up=$1 down=$2
    local today=$(date +%F)
    
    jq --arg t "$today" \
       --argjson u $up \
       --argjson d $down \
       '.total_up += $u | .total_down += $d | 
        .daily[$t].up = (.daily[$t].up // 0) + $u |
        .daily[$t].down = (.daily[$t].down // 0) + $d' \
       $STATS_FILE > tmp.$$.json && mv tmp.$$.json $STATS_FILE
}

show_stats() {
    [[ ! -f $STATS_FILE ]] && color_echo $YELLOW "尚未生成统计数据" && return
    
    local total_up=$(jq -r '.total_up' $STATS_FILE)
    local total_down=$(jq -r '.total_down' $STATS_FILE)
    
    echo -e "${CYAN}=== 流量统计 ===${PLAIN}"
    echo -e "总上传：$(numfmt --to=iec $total_up)"
    echo -e "总下载：$(numfmt --to=iec $total_down)"
    
    echo -e "\n${CYAN}近日统计${PLAIN}"
    jq -r '.daily | to_entries[-7:] | reverse[] | 
        "\(.key): ↑\(.value.up|tobytes) ↓\(.value.down|tobytes)"' $STATS_FILE
}

# 协议混淆
configure_obfs() {
    color_echo $YELLOW "请选择混淆方式："
    select obfs in "无混淆" "HTTP伪装" "随机填充"; do
        case $obfs in
            "HTTP伪装")
                OBFS_TYPE="salamander"
                read -p "设置混淆密码（默认随机生成）：" OBFS_PWD
                OBFS_PWD=${OBFS_PWD:-$(openssl rand -hex 8)}
                OBFS_OPTIONS="
obfs:
  type: $OBFS_TYPE
  salamander:
    password: \"$OBFS_PWD\""
                break ;;
            "随机填充")
                OBFS_TYPE="random-padding"
                OBFS_OPTIONS="
obfs:
  type: $OBFS_TYPE
  random-padding:
    padding-up: 1500
    padding-down: 1500" 
                break ;;
            *) OBFS_OPTIONS="" && break ;;
        esac
    done
}

# 生成配置文件
generate_config() {
    cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}
tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}
auth:
  type: password
  password: ${PASSWORD}
bandwidth:
  up: 0
  down: 0
${OBFS_OPTIONS}
masquerade:
  type: reverse_proxy
  proxy:
    url: https://connect.rom.miui.com
    rewriteHost: true
EOF
}

# 查询实时流量
get_realtime_stats() {
    local stats=$(timeout 5 curl -s http://localhost:8080/live)
    [[ -z $stats ]] && return
    
    local conns=$(jq '.connections' <<< "$stats")
    local up=$(jq -r '.bytesSent' <<< "$stats")
    local down=$(jq -r '.bytesReceived' <<< "$stats")
    
    echo -e "${CYAN}实时统计${PLAIN}"
    echo -e "活跃连接：$conns"
    echo -e "当前上传速率：$(numfmt --to=iec $up)/s"
    echo -e "当前下载速率：$(numfmt --to=iec $down)/s"
}

# 安装流程
install() {
    clear
    color_echo $GREEN "===== Hysteria 2 安装向导 ====="
    
    # 依赖安装
    system=$(detect_system)
    [[ $system == "unknown" ]] && fatal "不支持的操作系统"
    
    color_echo $YELLOW "正在安装系统依赖..."
    case $system in
        debian)
            apt update && apt install -y jq socat qrencode ;;
        centos)
            yum install -y jq socat qrencode ;;
    esac
    
    # 证书配置
    color_echo $GREEN "请选择证书类型："
    select cert_mode in "自签证书" "Let's Encrypt证书" "手动上传"; do
        case $cert_mode in
            "自签证书")
                DOMAIN="www.bing.com"
                openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/key.pem
                openssl req -new -x509 -days 365 -key /etc/hysteria/key.pem \
                    -out /etc/hysteria/cert.pem -subj "/CN=$DOMAIN"
                CERT_FILE="/etc/hysteria/cert.pem"
                KEY_FILE="/etc/hysteria/key.pem"
                break ;;
                
            "Let's Encrypt证书")
                read -p "输入域名（需已解析到本机）：" DOMAIN
                [[ -z $DOMAIN ]] && fatal "域名不能为空"
                
                # ACME 申请流程
                curl https://get.acme.sh | sh -s email=$(date +%s)@temp.com
                ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --force
                ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
                    --key-file /etc/hysteria/key.pem \
                    --fullchain-file /etc/hysteria/cert.pem
                CERT_FILE="/etc/hysteria/cert.pem"
                KEY_FILE="/etc/hysteria/key.pem"
                break ;;
                
            "手动上传")
                read -e -p "证书文件路径：" CERT_FILE
                read -e -p "私钥文件路径：" KEY_FILE
                [[ ! -f $CERT_FILE || ! -f $KEY_FILE ]] && fatal "证书文件不存在"
                cp $CERT_FILE /etc/hysteria/cert.pem
                cp $KEY_FILE /etc/hysteria/key.pem
                read -p "证书域名：" DOMAIN
                CERT_FILE="/etc/hysteria/cert.pem"
                KEY_FILE="/etc/hysteria/key.pem"
                break ;;
        esac
    done
    
    # 端口设置
    while true; do
        read -p "监听端口（默认8443）：" PORT
        PORT=${PORT:-8443}
        [[ $PORT =~ ^[0-9]+$ ]] && [ $PORT -le 65535 ] && break
        color_echo $RED "端口号不合法！"
    done
    
    # 密码设置
    PASSWORD=$(openssl rand -base64 12 | tr -d '=+/')
    
    # 协议混淆设置
    configure_obfs
    
    generate_config
    
    # 服务文件
    cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    
    # 下载核心
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$ARCH"
    if ! wget -O /usr/local/bin/hysteria $HY_URL; then
        fatal "核心下载失败"
    fi
    chmod +x /usr/local/bin/hysteria
    
    systemctl daemon-reload
    systemctl enable --now hysteria
    
    # 生成客户端配置
    IP=$(curl -4s ip.gs || curl -6s ip.gs)
    CLIENT_JSON="/root/hy/client.json"
    cat > $CLIENT_JSON <<EOF
{
  "server": "$IP:$PORT",
  "auth": "$PASSWORD",
  "tls": {
    "sni": "$DOMAIN",
    "insecure": true
  },
  "obfs": "${OBFS_PWD:-}"
}
EOF
    
    color_echo $GREEN "\n安装完成！客户端配置文件：$CLIENT_JSON"
    qrencode -t ANSIUTF8 < $CLIENT_JSON
}

# 主菜单
menu() {
    while true; do
        clear
        echo -e "${GREEN}===== Hysteria 2 管理菜单 ====${PLAIN}"
        echo "1. 全新安装"
        echo "2. 查看配置"
        echo "3. 协议混淆设置"
        echo "4. 流量统计"
        echo "5. 服务状态查看"
        echo "6. 完全卸载"
        echo -e "${RED}0. 退出脚本${PLAIN}"
        echo "------------------------------"
        
        read -p "请输入选择 [0-6]: " choice
        
        case $choice in
            1) install ;;
            2) [[ -f /root/hy/client.json ]] && jq . /root/hy/client.json ;;
            3) configure_obfs && systemctl restart hysteria ;;
            4) show_stats ;;
            5) systemctl status hysteria && get_realtime_stats ;;
            6) systemctl stop hysteria
               rm -rf /etc/hysteria /usr/local/bin/hysteria
               color_echo $GREEN "已卸载所有组件" ;;
            0) exit 0 ;;
            *) color_echo $RED "无效选择，请重新输入" ;;
        esac
        
        echo && read -p "按回车返回菜单..."
    done
}

# 初始化
init_dirs
init_stats
menu
