#!/usr/bin/env bash
# Hysteria 2
# Author: Hysteria-Enhanced-Team
# License: MIT
# GitHub: https://github.com/your-repo

# ███████████████████████████████████████████████████████
# █                                                            █
# █   ██╗  ██╗██╗   ██╗███████╗████████╗██████╗ ██╗ █████╗      █
# █   ██║  ██║╚██╗ ██╔╝██╔════╝╚══██╔══╝██╔══██╗██║██╔══██╗     █
# █   ███████║ ╚████╔╝ ███████╗   ██║   ██████╔╝██║███████║     █
# █   ██╔══██║  ╚██╔╝  ╚════██║   ██║   ██╔══██╗██║██╔══██║     █
# █   ██║  ██║   ██║   ███████║   ██║   ██║  ██║██║██║  ██║     █
# █   ╚═╝  ╚═╝   ╚═╝   ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝     █
# █                                                            █
# █████████████████████████████████████████████████████████████

#!/usr/bin/env bash
# 修复版安装脚本核心部分

install_hysteria() {
    # 确保服务停止
    systemctl stop hysteria-server 2>/dev/null
    pkill -9 hysteria
    sleep 2  # 等待进程释放

    # 创建临时目录
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    # 获取架构信息
    case $(uname -m) in
        x86_64)  HY_ARCH="amd64" ;;
        aarch64) HY_ARCH="arm64" ;;
        armv7l)  HY_ARCH="arm" ;;
        *) log ERROR "Unsupported architecture"; exit 1 ;;
    esac

    # 带重试机制的下载
    for i in {1..3}; do
        LATEST_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep tag_name | cut -d'"' -f4)
        DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/$LATEST_VER/hysteria-linux-$HY_ARCH"
        
        if curl -L -o hysteria \
            --connect-timeout 30 \
            --retry 3 \
            --retry-delay 10 \
            "$DOWNLOAD_URL"; then
            break
        elif [[ $i -eq 3 ]]; then
            log ERROR "Download failed after 3 attempts"
            exit 1
        fi
        sleep $((i*5))
    done

    # 原子操作替换文件
    sudo install -m 755 hysteria /usr/local/bin/hysteria.new
    sudo mv /usr/local/bin/hysteria.new /usr/local/bin/hysteria

    # 清理临时文件
    cd ..
    rm -rf "$temp_dir"
}

# 配置常量
HYSTERIA_BIN="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
SERVICE_DIR="/etc/systemd/system"
SCRIPT_NAME=$(basename "$0")

# 颜色编码
RED='\033[1;31m'; GREEN='\033[1;32m'
YELLOW='\033[1;33m'; BLUE='\033[1;36m'
PLAIN='\033[0m'; BOLD='\033[1m'

# 全局变量
IP=""; PORT=""; PASSWORD=""
MASQUERADE_SITE="en.snu.ac.kr"

# ► 日志系统 ◄
log() {
    local level=$1; shift
    local color=""; local prefix=""
    case $level in
        "INFO") color=$BLUE; prefix="[ℹ]" ;;
        "SUCCESS") color=$GREEN; prefix="[✓]" ;;
        "WARN") color=$YELLOW; prefix="[⚠]" ;;
        "ERROR") color=$RED; prefix="[✗]" ;;
    esac
    echo -e "${color}$(date +"%Y-%m-%d %T") ${prefix} $* ${PLAIN}"
}

# ► 初始检查 ◄
check_root() {
    [[ $EUID -ne 0 ]] && {
        log ERROR "必须使用 root 权限运行！"
        exit 1
    }
}

# ► 智能依赖安装 ◄
install_deps() {
    declare -A PKG_MAP=(
        [apt]="iptables-persistent netfilter-persistent"
        [yum]="iptables-services"
        [dnf]="iptables-services" 
        [zypper]="iptables"
        [pacman]="iptables"
    )

    local mgr=""
    for cmd in apt yum dnf zypper pacman; do
        command -v $cmd &>/dev/null && mgr=$cmd && break
    done
    [[ -z $mgr ]] && log ERROR "不支持的包管理器" && exit 1

    log INFO "检测到包管理器: ${mgr^^}"

    # 基础依赖列表
    local base_deps=("curl" "wget" "jq" "openssl" "qrencode")
    local special_deps=(${PKG_MAP[$mgr]})
    local all_deps=("${base_deps[@]}" "${special_deps[@]}")

    # 安装流程
    case $mgr in
        apt) export DEBIAN_FRONTEND=noninteractive; $mgr update ;;
        yum|dnf) $mgr makecache ;;
    esac

    for pkg in "${all_deps[@]}"; do
        if ! command -v $pkg &>/dev/null; then
            log INFO "正在安装: $pkg..."
            $mgr install -y $pkg &>/dev/null || log WARN "安装失败: $pkg"
        fi
    done
}

# ► IP地址检测 ◄
get_ip() {
    IP=$(curl -4s https://ipinfo.io/ip || curl -6s https://ipinfo.io/ip)
    [[ -z $IP ]] && {
        log WARN "无法自动获取IP，请手动输入！"
        read -p "请输入服务器公网IP: " IP
        [[ -z $IP ]] && log ERROR "必须提供有效IP地址！" && exit 1
    }
}

# ► 证书管理 ◄
manage_cert() {
    case $1 in
        self-signed)
            log INFO "生成自签名证书..."
            openssl ecparam -genkey -name prime256v1 -out $CONFIG_DIR/server.key
            openssl req -new -x509 -days 365 -key $CONFIG_DIR/server.key \
                -out $CONFIG_DIR/server.crt -subj "/CN=bing.com"
            ;;
        custom)
            read -p "证书文件路径: " cert_path
            read -p "私钥文件路径: " key_path
            cp "$cert_path" $CONFIG_DIR/server.crt
            cp "$key_path" $CONFIG_DIR/server.key
            ;;
        *) log ERROR "未知证书类型"; exit 1 ;;
    esac
    chmod 600 $CONFIG_DIR/server.*
}

# ► 服务管理 ◄
service_ctl() {
    case $1 in
        start|stop|restart|status|enable|disable)
            systemctl $1 hysteria-server &>/dev/null
            local result=$?
            [[ $result -eq 0 ]] && log SUCCESS "操作成功: $1" || log ERROR "操作失败"
            return $result
            ;;
        *) log ERROR "无效操作"; return 1 ;;
    esac
}

# ► 生成配置文件 ◄
generate_config() {
    cat > $CONFIG_DIR/config.yaml <<EOF
listen: :${PORT}
tls:
  cert: ${CONFIG_DIR}/server.crt
  key: ${CONFIG_DIR}/server.key

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://${MASQUERADE_SITE}
    rewriteHost: true
EOF
}

# ► 核心安装流程 ◄
install_core() {
    log INFO "获取最新版本..."
    LATEST_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    [[ -z $LATEST_VER ]] && log ERROR "版本获取失败" && exit 1

    # 架构检测
    case $(uname -m) in
        x86_64) ARCH="amd64";;
        aarch64) ARCH="arm64";;
        armv7l) ARCH="arm";;
        *) log ERROR "不支持架构: $(uname -m)"; exit 1 ;;
    esac

    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${LATEST_VER}/hysteria-linux-${ARCH}"
    
    log INFO "下载核心文件..."
    if ! curl -L -o "$HYSTERIA_BIN" "$DOWNLOAD_URL"; then
        log ERROR "下载失败！可能原因："
        log ERROR "1. 网络连接问题"
        log ERROR "2. GitHub API限制"
        exit 1
    fi
    chmod +x "$HYSTERIA_BIN"
}

# ► 主安装函数 ◄
main_install() {
    clear
    echo -e "${BOLD}‖►►► Hysteria 2 安装向导 ◄◄◄‖${PLAIN}"
    
    check_root
    get_ip
    install_deps
    install_core

    # 证书选择
    echo -e "\n${BOLD}证书类型选择：${PLAIN}"
    echo -e "1) 自签名证书（默认）"
    echo -e "2) 自定义证书"
    read -p "选项 [1-2]: " cert_type
    case ${cert_type:-1} in
        1) manage_cert self-signed ;;
        2) manage_cert custom ;;
        *) log ERROR "无效选择"; exit 1 ;;
    esac

    # 端口配置
    while :; do
        read -p "监听端口 (默认随机): " port
        PORT=${port:-$(shuf -i 10000-65535 -n 1)}
        ss -tuln | grep -q ":${PORT} " || break
        log WARN "端口 ${PORT} 已被占用！"
    done

    # 生成密码
    PASSWORD=$(openssl rand -base64 12)
    log INFO "连接密码已生成: ${PASSWORD}"

    # 伪装配置
    read -p "伪装网站 [默认为en.snu.ac.kr]: " site
    MASQUERADE_SITE=${site:-en.snu.ac.kr}

    # 生成配置文件
    mkdir -p "$CONFIG_DIR"
    generate_config

    # 服务配置
    cat > $SERVICE_DIR/hysteria-server.service <<EOF
[Unit]
Description=Hysteria 2 Server Service
After=network.target

[Service]
User=root
ExecStart=$HYSTERIA_BIN server -c $CONFIG_DIR/config.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-server
    log SUCCESS "安装完成！"
}

# ► 安装后菜单 ◄
show_menu() {
    clear
    echo -e "${BOLD}‖►►► Hysteria 2 管理菜单 ◄◄◄‖${PLAIN}"
    echo -e "${GREEN}1. 安装/重装"
    echo -e "${BLUE}2. 查看配置"
    echo -e "${YELLOW}3. 启动服务"
    echo -e "${YELLOW}4. 停止服务"
    echo -e "${BLUE}5. 重启服务"
    echo -e "${RED}6. 完全卸载"
    echo -e "${PLAIN}0. 退出脚本"
    echo -e "\n${BOLD}服务状态: ${PLAIN}$(systemctl is-active hysteria-server 2>/dev/null || echo '未安装')"
}

# ► 主逻辑控制 ◄
case $1 in
    install) main_install ;;
    *)
        while true; do
            show_menu
            read -p "请选择操作: " choice
            case $choice in
                1) main_install ;;
                2) 
                    echo -e "${GREEN}服务器地址: ${IP}:${PORT}"
                    echo -e "连接密码: ${PASSWORD}"
                    echo -e "伪装网址: ${MASQUERADE_SITE}${PLAIN}"
                    ;;
                3) service_ctl start ;;
                4) service_ctl stop ;;
                5) service_ctl restart ;;
                6) 
                    service_ctl stop
                    rm -rf "$HYSTERIA_BIN" "$CONFIG_DIR" 
                    rm -f $SERVICE_DIR/hysteria-server.service
                    systemctl daemon-reload
                    log SUCCESS "已完全移除"
                    ;;
                0) exit 0 ;;
                *) log WARN "无效选项，请重新输入" ;;
            esac
            read -n1 -s -p "按任意键继续..."
        done
        ;;
esac
