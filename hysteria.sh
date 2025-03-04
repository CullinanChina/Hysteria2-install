#!/bin/bash

# 定义颜色代码
RED="\033[31m"       GREEN="\033[32m"      YELLOW="\033[33m"
BLUE="\033[36m"      PLAIN="\033[0m"

# 定义平台相关配置
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "amazon linux" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
CMD=("/etc/os-release" "hostnamectl" "lsb_release -sd" "/etc/lsb-release" "/etc/redhat-release" "/etc/issue")

# 功能函数
color(){
    echo -e "\033[3$1m\033[4$2m$3\033[0m" 
}

show_menu(){
    clear
    color 6 1 " ░▒▓███████▓▒░ ░▒▓██████▓▒░  ░▒▓███████▓▒░  ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓████████▓▒░ "
    color 6 1 "░▒▓█▓▒░░▒▓█▓▒░▒▓█▓▒░░▒▓█▓▒░▒▓█▓▒░          ░▒▓█▓▒░░▒▓█▓▒░▒▓█▓▒░         "
    color 6 1 "░▒▓█▓▒░░▒▓█▓▒░▒▓█▓▒░░▒▓█▓▒░▒▓█▓▒░          ░▒▓█▓▒░░▒▓█▓▒░▒▓█▓▒░         "
    color 6 1 "░▒▓█▓▒░░▒▓█▓▒░▒▓█▓▒░░▒▓█▓▒░ ░▒▓██████▓▒░   ░▒▓█▓▒░░▒▓█▓▒░░▒▓██████▓▒░   "
    color 6 1 "░▒▓█▓▒░░▒▓█▓▒░▒▓█▓▒░░▒▓█▓▒░       ░▒▓█▓▒░  ░▒▓█▓▒░░▒▓█▓▒░      ░▒▓█▓▒░ "
    color 6 1 "░▒▓█▓▒░░▒▓█▓▒░▒▓█▓▒░░▒▓█▓▒░       ░▒▓█▓▒░  ░▒▓█▓▒░░▒▓█▓▒░      ░▒▓█▓▒░ "
    color 6 1 " ░▒▓███████▓▒░ ░▒▓██████▓▒░ ░▒▓███████▓▒░   ░▒▓███████▓▒░ ░▒▓███████▓▒░ "
    echo -e "\n${GREEN}Hysteria 2 Enhanced Installer v3.0${PLAIN}"
    echo -e "${BLUE}GitHub: https://github.com/hysec-io/hysteria2-installer${PLAIN}\n"
    echo -e "${YELLOW}1. ${GREEN}安装 Hysteria 2"
    echo -e "2. ${RED}卸载 Hysteria 2"
    echo -e "${YELLOW}3. 服务管理 (启动/停止/重启)"
    echo -e "4. 配置管理 (端口|密码|证书|伪装站点)"
    echo -e "5. 显示客户端配置"
    echo -e "6. 更新内核版本"
    echo -e "0. 退出脚本${PLAIN}"
    echo -e "\n${BLUE}当前服务状态: $(systemctl is-active hysteria-server 2>/dev/null || echo '未安装')${PLAIN}"
}

init_system(){
    [[ $EUID -ne 0 ]] && echo "请使用 root 权限运行脚本" && exit 1
    SYS=$( (grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release || cat /etc/issue) 2>/dev/null)
    [[ -z $SYS ]] && echo "不支持的发行版" && exit 1

    for ((i=0; i<${#REGEX[@]}; i++)); do
        [[ $SYS =~ ${REGEX[i]} ]] && SYSTEM=${RELEASE[i]} && break
    done

    [[ -z $SYSTEM ]] && echo "不支持的发行版" && exit 1
    (( ${PACKAGE_UPDATE[int]} )) 2>/dev/null || ${PACKAGE_INSTALL[int]} curl
}

core_install(){
    local url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$(
    case $(arch) in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) exit 1 ;;
    esac)"
    
    if ! wget -qO /usr/local/bin/hysteria $url; then
        echo "核心下载失败!" 
        return 1
    fi
    chmod +x /usr/local/bin/hysteria
}

port_handler(){
    local type=$1
    case $type in
        check)
            while ss -ulpn | grep -q ":$2 "; do
                echo -n "$2 "
                ((port++))
            done ;;
        redir)
            iptables -t nat -A PREROUTING -p udp --dport $2:$3 -j DNAT --to-destination :$4
            ip6tables -t nat -A PREROUTING -p udp --dport $2:$3 -j DNAT --to-destination :$4
            netfilter-persistent save 2>/dev/null ;;
    esac
}

cert_manager(){
    local ops=$1
    case $ops in
        selfsign)
            mkdir -p /etc/hysteria
            openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key
            openssl req -new -x509 -days 36500 -key /etc/hysteria/private.key \
                -out /etc/hysteria/cert.crt -subj "/CN=www.bing.com" ;;
        acme)
            curl https://get.acme.sh | sh -s email=$(openssl rand -hex 12)@hysec.com
            ~/.acme.sh/acme.sh --upgrade --auto-upgrade
            if [[ $ip =~ : ]]; then
                ~/.acme.sh/acme.sh --issue -d $domain --standalone --listen-v6 --force
            else
                ~/.acme.sh/acme.sh --issue -d $domain --standalone --force
            fi
            ~/.acme.sh/acme.sh --install-cert -d $domain \
                --key-file /etc/hysteria/private.key \
                --fullchain-file /etc/hysteria/cert.crt ;;
    esac
}

config_generator(){
    local protocol=$([ $jump_mode -eq 1 ] && echo "$start_port-$end_port,$port" || echo $port)
    cat > /etc/hysteria/config.yaml <<EOF
listen: :$port
tls:
  cert: ${cert_path:-/etc/hysteria/cert.crt}
  key: ${key_path:-/etc/hysteria/private.key}
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216 
auth:
  type: password
  password: $password

masquerade:
  type: proxy
  proxy:
    url: https://${site:-maimai.sega.jp}
    rewriteHost: true
EOF

    local ip_formatted=$([ ${ip} =~ : ] && echo "[$ip]" || echo $ip)
    cat > /root/hy/client.yaml <<EOF
server: $ip_formatted:$protocol
auth: $password
socks5:
  listen: 127.0.0.1:${socks_port:-5080}
transport:
  udp:
    hopInterval: 30s
EOF
    qrencode -t UTF8 "hysteria2://$password@$ip:$protocol/?insecure=1&sni=${domain:-www.bing.com}#HySec-$(date +%s)"
}

# 主流程控制
case $1 in
    install)
        init_system
        core_install || exit 1
        # 更多交互步骤...
        ;;
    *)
        while true; do
            show_menu
            read -p "请输入选项: " opt
            case $opt in
                1) install_hysteria ;;
                2) remove_hysteria ;;
                3) service_control ;;
                4) config_menu ;;
                5) show_config ;;
                6) update_core ;;
                0) exit 0 ;;
            esac
        done ;;
esac
