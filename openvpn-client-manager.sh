#!/bin/sh
# 
# OpenVPN 客户端管理脚本 v2.0 - 兼容 Alpine & Debian/Ubuntu
# 功能增强版：
#   原有: 安装/导入.ovpn/连接/断开/开机自启/卸载/查看日志
#   新增: 多配置文件管理/连接检测增强(tun+IP)/DNS泄漏检测/自动重连/彩色输出/审计日志/非交互模式
# POSIX 兼容 (ash/dash/bash)
# 

# ─
# 彩色输出函数
# ─
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1) GREEN=$(tput setaf 2) YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6) BOLD=$(tput bold) RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
fi

msg_ok()   { printf "%s[OK] %s%s\n" "${GREEN}"  "$1" "${RESET}"; }
msg_err()  { printf "%s[ERR] %s%s\n" "${RED}"    "$1" "${RESET}"; }
msg_warn() { printf "%s[WARN] %s%s\n" "${YELLOW}" "$1" "${RESET}"; }
msg_info() { printf "%s[INFO] %s%s\n" "${CYAN}"   "$1" "${RESET}"; }

# 
# 审计日志
# 
AUDIT_LOG="/var/log/openvpn-client-admin.log"
audit() {
    _ts=$(date '+%Y-%m-%d %H:%M:%S')
    _user=$(whoami)
    printf '[%s] user=%s action="%s"\n' "$_ts" "$_user" "$*" >> "$AUDIT_LOG" 2>/dev/null || true
}

# 
# Root 权限检查
# 
if [ "$(id -u)" -ne 0 ]; then
    msg_err "请以 root 用户运行此脚本"
    exit 1
fi

# 
# 检测系统类型并设置变量
# 
if [ -f /etc/alpine-release ]; then
    OS="alpine"
    PKG_INSTALL="apk add --no-cache"
    PKG_REMOVE="apk del --purge"
    PKG_UPDATE="apk update"
    SERVICE_START="rc-service openvpn start"
    SERVICE_STOP="rc-service openvpn stop"
    SERVICE_RESTART="rc-service openvpn restart"
    SERVICE_ENABLE="rc-update add openvpn default"
    SERVICE_DISABLE="rc-update del openvpn default"
    CONFIG_DIR="/etc/openvpn"
    CONFIG_FILE="$CONFIG_DIR/openvpn.conf"
    LOG_FILE="/var/log/openvpn-client.log"
    USE_SYSTEMD=0
elif [ -f /etc/debian_version ] || grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
    OS="debian"
    PKG_INSTALL="apt install -y"
    PKG_REMOVE="apt purge -y"
    PKG_UPDATE="apt update"
    SERVICE_START="systemctl start openvpn@client"
    SERVICE_STOP="systemctl stop openvpn@client"
    SERVICE_RESTART="systemctl restart openvpn@client"
    SERVICE_ENABLE="systemctl enable openvpn@client"
    SERVICE_DISABLE="systemctl disable openvpn@client"
    CONFIG_DIR="/etc/openvpn"
    CONFIG_FILE="$CONFIG_DIR/client.conf"
    LOG_FILE="/var/log/openvpn-client.log"
    USE_SYSTEMD=1
else
    msg_err "不支持的系统！仅支持 Alpine 或 Debian/Ubuntu"
    exit 1
fi

PROFILES_DIR="$CONFIG_DIR/profiles"
mkdir -p "$PROFILES_DIR"

# ─
# 辅助函数：检查 VPN 连接状态（增强版）
# 
check_vpn_connected() {
    if ! ip link show tun0 >/dev/null 2>&1; then
        return 1
    fi
    _tun_ip=$(ip -4 addr show tun0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    if [ -z "$_tun_ip" ]; then
        return 1
    fi
    return 0
}

# 
# 辅助函数：获取 VPN 连接详情
# ─
get_vpn_info() {
    VPN_IP=""
    VPN_GW=""
    VPN_REMOTE=""
    if ip link show tun0 >/dev/null 2>&1; then
        VPN_IP=$(ip -4 addr show tun0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
        VPN_GW=$(ip route show dev tun0 2>/dev/null | grep 'via' | head -1 | awk '{print $3}')
    fi
    if [ -f "$CONFIG_FILE" ]; then
        VPN_REMOTE=$(grep -i '^remote ' "$CONFIG_FILE" | head -1 | awk '{print $2, $3}')
    fi
}

# 
# 辅助函数：列出已保存的配置文件
# 
list_profiles() {
    PROFILE_LIST=""
    PROFILE_COUNT=0
    for _p in "$PROFILES_DIR"/*.ovpn; do
        [ ! -f "$_p" ] && continue
        _pname=$(basename "$_p" .ovpn)
        PROFILE_LIST="$PROFILE_LIST $_pname"
        PROFILE_COUNT=$((PROFILE_COUNT + 1))
    done
    PROFILE_LIST=$(echo "$PROFILE_LIST" | sed 's/^ //')
}

# 
# 辅助函数：选择配置文件
# 
select_profile() {
    _prompt="${1:-选择配置文件}"
    list_profiles
    if [ "$PROFILE_COUNT" -eq 0 ]; then
        msg_warn "暂无已保存的配置文件"
        SELECTED_PROFILE=""
        return 1
    fi
    set -- $PROFILE_LIST
    _i=1
    while [ $# -gt 0 ]; do
        _active=""
        if [ -f "$CONFIG_FILE" ] && [ -f "$PROFILES_DIR/$1.ovpn" ]; then
            if cmp -s "$CONFIG_FILE" "$PROFILES_DIR/$1.ovpn" 2>/dev/null; then
                _active=" ${GREEN}<- current${RESET}"
            fi
        fi
        printf "  %d) %s%b\n" "$_i" "$1" "$_active"
        shift
        _i=$((_i + 1))
    done
    echo ""
    printf "%s (1-%s, q=back): " "$_prompt" "$((_i - 1))"
    read _sel
    [ "$_sel" = "q" ] || [ "$_sel" = "Q" ] && { SELECTED_PROFILE=""; return 1; }
    if ! echo "$_sel" | grep -qE '^[0-9]+$' || [ "$_sel" -lt 1 ] || [ "$_sel" -ge "$_i" ]; then
        msg_err "无效选择"
        SELECTED_PROFILE=""
        return 1
    fi
    set -- $PROFILE_LIST
    _j=1
    while [ "$_j" -lt "$_sel" ]; do shift; _j=$((_j + 1)); done
    SELECTED_PROFILE="$1"
    return 0
}

# ─
# 辅助函数：DNS 泄漏检测
# 
check_dns_leak() {
    echo "${BOLD}=== DNS 泄漏检测 ===${RESET}"
    echo ""

    if ! check_vpn_connected; then
        msg_err "VPN 未连接，无法检测 DNS 泄漏"
        return 1
    fi

    msg_info "正在检测公网 IP..."
    _pub_ip=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || curl -s --max-time 10 icanhazip.com 2>/dev/null)
    if [ -n "$_pub_ip" ]; then
        msg_info "当前公网 IP: $_pub_ip"
    else
        msg_warn "无法获取公网 IP"
    fi

    echo ""
    msg_info "当前 DNS 服务器："
    if [ -f /etc/resolv.conf ]; then
        _dns_servers=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}')
        if [ -n "$_dns_servers" ]; then
            for _dns in $_dns_servers; do
                case "$_dns" in
                    10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*)
                        printf "  %s ${GREEN}(VPN 内网地址)${RESET}\n" "$_dns" ;;
                    127.*)
                        printf "  %s ${YELLOW}(本地回环)${RESET}\n" "$_dns" ;;
                    *)
                        printf "  %s ${YELLOW}(公网 DNS - 注意潜在泄漏)${RESET}\n" "$_dns" ;;
                esac
            done
        fi
    fi

    echo ""
    msg_info "DNS 解析测试..."
    if command -v nslookup >/dev/null 2>&1; then
        _result=$(nslookup whoami.akamai.net 2>/dev/null | grep 'Address' | tail -1 | awk '{print $2}')
        if [ -n "$_result" ]; then
            msg_info "DNS 解析出口 IP: $_result"
        fi
    elif command -v dig >/dev/null 2>&1; then
        _result=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null)
        if [ -n "$_result" ]; then
            msg_info "DNS 解析出口 IP: $_result"
        fi
    else
        msg_warn "未安装 nslookup 或 dig，跳过高级检测"
    fi

    echo ""
    if [ -n "$_pub_ip" ]; then
        _remote_ip=""
        if [ -f "$CONFIG_FILE" ]; then
            _remote_ip=$(grep -i '^remote ' "$CONFIG_FILE" | head -1 | awk '{print $2}')
        fi
        if [ -n "$_remote_ip" ] && [ "$_pub_ip" != "$_remote_ip" ]; then
            msg_ok "公网 IP 与 VPN 服务器 IP 不同（正常 — 流量经网关客户端出口）"
            msg_info "  公网 IP:    $_pub_ip"
            msg_info "  服务器 IP:  $_remote_ip"
            msg_info "  说明: 流量路径为 VPN Server -> 网关客户端 -> 互联网"
            msg_info "        所以出口 IP 是网关客户端的公网 IP，而不是 VPN 服务器"
        elif [ -n "$_remote_ip" ]; then
            msg_warn "公网 IP 与 VPN 服务器 IP 相同"
            msg_info "  如果使用了分流（国内直连），这可能是正常的"
            msg_info "  如果预期流量走网关客户端出口，请检查服务端路由配置"
        fi
    fi

    return 0
}

# ═
# 非交互模式支持
# 
if [ $# -gt 0 ]; then
    case "$1" in
        --connect)
            PROFILE_NAME="$2"
            if [ -n "$PROFILE_NAME" ] && [ -f "$PROFILES_DIR/${PROFILE_NAME}.ovpn" ]; then
                cp "$PROFILES_DIR/${PROFILE_NAME}.ovpn" "$CONFIG_FILE"
                chmod 600 "$CONFIG_FILE"
            fi
            if [ ! -f "$CONFIG_FILE" ]; then
                msg_err "未找到配置文件 $CONFIG_FILE"; exit 1
            fi
            $SERVICE_START >/dev/null 2>&1 || true
            sleep 3
            if check_vpn_connected; then
                audit "非交互连接: ${PROFILE_NAME:-default}"
                msg_ok "VPN 已连接"
            else
                msg_err "VPN 连接失败"; exit 1
            fi
            exit 0
            ;;
        --disconnect)
            $SERVICE_STOP 2>/dev/null || true
            audit "非交互断开"
            msg_ok "VPN 已断开"
            exit 0
            ;;
        --status)
            if check_vpn_connected; then
                get_vpn_info
                msg_ok "VPN 已连接"
                [ -n "$VPN_IP" ] && msg_info "VPN IP: $VPN_IP"
                [ -n "$VPN_REMOTE" ] && msg_info "远程: $VPN_REMOTE"
            else
                msg_err "VPN 未连接"
            fi
            exit 0
            ;;
        --import)
            OVPN_PATH="$2"; PROFILE_NAME="$3"
            if [ -z "$OVPN_PATH" ] || [ ! -f "$OVPN_PATH" ]; then
                msg_err "用法: $0 --import /path/to/file.ovpn [profile-name]"; exit 1
            fi
            [ -z "$PROFILE_NAME" ] && PROFILE_NAME=$(basename "$OVPN_PATH" .ovpn)
            cp "$OVPN_PATH" "$PROFILES_DIR/${PROFILE_NAME}.ovpn"
            chmod 600 "$PROFILES_DIR/${PROFILE_NAME}.ovpn"
            audit "非交互导入: $PROFILE_NAME"
            msg_ok "已导入为: $PROFILE_NAME"
            exit 0
            ;;
        --list)
            list_profiles
            if [ "$PROFILE_COUNT" -eq 0 ]; then echo "暂无配置文件"
            else echo "$PROFILE_LIST" | tr ' ' '\n'; fi
            exit 0
            ;;
        --reconnect)
            PROFILE_NAME="$2"
            $SERVICE_STOP 2>/dev/null || true; sleep 1
            if [ -n "$PROFILE_NAME" ] && [ -f "$PROFILES_DIR/${PROFILE_NAME}.ovpn" ]; then
                cp "$PROFILES_DIR/${PROFILE_NAME}.ovpn" "$CONFIG_FILE"
                chmod 600 "$CONFIG_FILE"
            fi
            $SERVICE_START >/dev/null 2>&1 || true; sleep 3
            if check_vpn_connected; then
                audit "非交互重连: ${PROFILE_NAME:-default}"
                msg_ok "VPN 已重连"
            else
                msg_err "VPN 重连失败"; exit 1
            fi
            exit 0
            ;;
        --dns-check)
            check_dns_leak; exit $? ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "非交互模式:"
            echo "  --connect [profile]         连接 VPN"
            echo "  --disconnect                断开 VPN"
            echo "  --reconnect [profile]       重连 VPN"
            echo "  --status                    查看连接状态"
            echo "  --import FILE [name]        导入 .ovpn 文件"
            echo "  --list                      列出所有配置文件"
            echo "  --dns-check                 DNS 泄漏检测"
            echo "  --help                      显示帮助"
            echo ""
            echo "不带参数则进入交互式菜单。"
            exit 0
            ;;
        *)
            msg_err "未知选项: $1 (使用 --help 查看帮助)"; exit 1 ;;
    esac
fi

# ═
# 交互式主菜单
# 
msg_info "检测到系统: $OS"
msg_info "配置文件: $CONFIG_FILE"
msg_info "日志文件: $LOG_FILE"
echo ""

while true; do
    clear

    # 顶部状态栏
    if check_vpn_connected; then
        get_vpn_info
        printf "%s VPN connected%s" "${GREEN}" "${RESET}"
        [ -n "$VPN_IP" ] && printf "  IP: %s" "$VPN_IP"
        [ -n "$VPN_REMOTE" ] && printf "  remote: %s" "$VPN_REMOTE"
        echo ""
    else
        printf "%s VPN disconnected%s\n" "${RED}" "${RESET}"
    fi
    echo ""

    echo "${BOLD}=== OpenVPN 客户端管理 v2.0 ===${RESET}"
    echo ""
    echo " ${GREEN} 1)${RESET} 安装 OpenVPN 客户端"
    echo " ${GREEN} 2)${RESET} 导入 .ovpn 配置文件"
    echo " ${GREEN} 3)${RESET} 连接 VPN"
    echo " ${GREEN} 4)${RESET} 断开 VPN"
    echo " ${GREEN} 5)${RESET} 设置开机自启"
    echo " ${GREEN} 6)${RESET} 取消开机自启"
    echo " ${GREEN} 7)${RESET} 查看连接状态 / 日志"
    echo " ${GREEN} 8)${RESET} 卸载 OpenVPN 客户端"
    echo " ${CYAN} 9)${RESET} 管理配置文件（多配置）"
    echo " ${CYAN}10)${RESET} 切换配置文件并连接"
    echo " ${CYAN}11)${RESET} DNS 泄漏检测"
    echo " ${CYAN}12)${RESET} 自动重连守护"
    echo " ${CYAN}13)${RESET} 查看审计日志"
    echo " ${RED} 0)${RESET} 退出脚本"
    echo ""
    printf "请选择操作（0~13，回车默认3）： "
    read mode_choice
    MODE=${mode_choice:-3}

    [ "$MODE" = "0" ] && { echo "已退出脚本。"; exit 0; }

    # ─
    # 模式1：安装 OpenVPN 客户端
    # ─
    if [ "$MODE" = "1" ]; then
        msg_info "正在安装 OpenVPN 客户端..."
        $PKG_UPDATE || msg_warn "更新包索引失败"
        $PKG_INSTALL openvpn || msg_warn "安装失败"

        if [ "$OS" = "alpine" ]; then
            # Alpine: 启用 sysctl 服务（确保 net.ipv4.ip_forward 等内核参数生效）
            if ! rc-update show default 2>/dev/null | grep -q sysctl; then
                rc-update add sysctl default 2>/dev/null && msg_ok "已添加 sysctl 到开机启动"
            fi
            rc-service sysctl start 2>/dev/null || true

            # 确保 IP 转发开启
            if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
                echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
                msg_info "已添加 net.ipv4.ip_forward=1 到 sysctl.conf"
            fi
            sysctl -p 2>/dev/null || sysctl -w net.ipv4.ip_forward=1 2>/dev/null

            # Alpine: 默认设置 OpenVPN 开机自启
            rc-update add openvpn default 2>/dev/null && msg_ok "已设置 OpenVPN 开机自启"
        fi

        audit "安装 OpenVPN 客户端"
        msg_ok "安装完成。"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # 
    # 模式2：导入 .ovpn 配置文件
    # 
    if [ "$MODE" = "2" ]; then
        printf "请输入 .ovpn 文件完整路径： "; read ovpn_path

        if [ -z "$ovpn_path" ] || [ ! -f "$ovpn_path" ]; then
            msg_err "文件不存在或路径无效"
            printf "按回车返回菜单..."; read dummy; continue
        fi

        _default_name=$(basename "$ovpn_path" .ovpn)
        printf "配置名称（回车使用 %s）： " "$_default_name"; read _pname
        _pname=${_pname:-$_default_name}

        # 保存到 profiles 目录
        cp "$ovpn_path" "$PROFILES_DIR/${_pname}.ovpn"
        chmod 600 "$PROFILES_DIR/${_pname}.ovpn"

        # 同时设为当前活动配置
        cp "$ovpn_path" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        chown root:root "$CONFIG_FILE" 2>/dev/null || true

        ADDED=0
        if ! grep -qi "^verb" "$CONFIG_FILE"; then
            echo "verb 3" >> "$CONFIG_FILE"
            ADDED=1
        fi
        if ! grep -qi "^log-append" "$CONFIG_FILE"; then
            echo "log-append $LOG_FILE" >> "$CONFIG_FILE"
            ADDED=1
        fi

        # 同步到 profile
        if ! grep -qi "^verb" "$PROFILES_DIR/${_pname}.ovpn"; then
            echo "verb 3" >> "$PROFILES_DIR/${_pname}.ovpn"
        fi
        if ! grep -qi "^log-append" "$PROFILES_DIR/${_pname}.ovpn"; then
            echo "log-append $LOG_FILE" >> "$PROFILES_DIR/${_pname}.ovpn"
        fi

        if [ $ADDED -eq 1 ]; then
            msg_info "已补全日志记录: $LOG_FILE"
        else
            msg_info "已包含 verb 和 log-append"
        fi

        audit "导入配置: $_pname (来源: $ovpn_path)"
        msg_ok "导入完成: 已保存为 '$_pname' 并设为当前活动配置"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─
    # 模式3：连接 VPN（增强检测）
    # ─
    if [ "$MODE" = "3" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            msg_err "未找到配置文件 $CONFIG_FILE"
            msg_info "请先使用模式 2 导入"
            printf "按回车继续..."; read dummy; continue
        fi

        if check_vpn_connected; then
            get_vpn_info
            msg_warn "VPN 已连接 (IP: ${VPN_IP:-未知})"
            printf "是否断开后重连？(y/n，回车 n)： "; read _rc
            if [ "${_rc:-n}" != "y" ]; then continue; fi
            $SERVICE_STOP 2>/dev/null || true
            sleep 1
        fi

        msg_info "正在连接 VPN..."
        $SERVICE_START >/dev/null 2>&1 || true

        echo "检查连接状态（每1秒检查一次，最多10次）..."

        SUCCESS=0
        i=1
        while [ "$i" -le 10 ]; do
            sleep 1
            printf "  检查 %d/10..." "$i"

            if check_vpn_connected; then
                get_vpn_info
                SUCCESS=1
                echo ""
                msg_ok "连接成功！"
                msg_info "VPN IP: ${VPN_IP:-未知}"
                [ -n "$VPN_REMOTE" ] && msg_info "远程服务器: $VPN_REMOTE"
                break
            fi

            if [ -f "$LOG_FILE" ]; then
                if tail -n 200 "$LOG_FILE" | grep -q "Initialization Sequence Completed"; then
                    sleep 1
                    get_vpn_info
                    SUCCESS=1
                    echo ""
                    msg_ok "连接成功！"
                    msg_info "VPN IP: ${VPN_IP:-未知}"
                    break
                fi
            fi

            printf " 等待中\n"
            i=$((i + 1))
        done

        if [ "$SUCCESS" -eq 0 ]; then
            echo ""
            msg_err "连接未成功（10秒内未检测到完成标志）"
            msg_info "请使用模式 7 查看详细日志"
            if [ -f "$LOG_FILE" ]; then
                echo ""
                msg_info "最近日志："
                tail -n 5 "$LOG_FILE" | sed 's/^/  /'
            fi
        fi

        audit "连接 VPN: success=$SUCCESS"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # 
    # 模式4：断开 VPN
    # 
    if [ "$MODE" = "4" ]; then
        msg_info "正在断开 VPN..."
        $SERVICE_STOP 2>/dev/null || msg_warn "服务已停止或未运行"
        sleep 1
        if check_vpn_connected; then
            msg_warn "tun 接口仍存在，尝试强制关闭..."
            ip link set tun0 down 2>/dev/null || true
            ip link delete tun0 2>/dev/null || true
        fi
        audit "断开 VPN"
        msg_ok "断开完成"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # 
    # 模式5：设置开机自启
    # 
    if [ "$MODE" = "5" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            msg_err "未找到配置文件"
            printf "按回车继续..."; read dummy; continue
        fi
        $SERVICE_ENABLE 2>/dev/null || true
        audit "设置开机自启"
        msg_ok "已设置开机自启"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # 
    # 模式6：取消开机自启
    # 
    if [ "$MODE" = "6" ]; then
        $SERVICE_DISABLE 2>/dev/null || true
        audit "取消开机自启"
        msg_ok "已取消开机自启"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # 
    # 模式7：查看连接状态 / 日志（增强版）
    # ─
    if [ "$MODE" = "7" ]; then
        echo "${BOLD}=== 连接详情 ===${RESET}"
        echo ""

        echo "服务状态："
        if [ "$OS" = "alpine" ]; then
            rc-service openvpn status 2>/dev/null || msg_warn "  服务未运行"
        else
            systemctl is-active openvpn@client >/dev/null 2>&1 && msg_ok "  服务运行中" || msg_err "  服务未运行"
        fi
        echo ""

        echo "VPN 连接："
        if check_vpn_connected; then
            get_vpn_info
            msg_ok "  已连接"
            [ -n "$VPN_IP" ] && msg_info "  VPN IP: $VPN_IP"
            [ -n "$VPN_GW" ] && msg_info "  网关: $VPN_GW"
            [ -n "$VPN_REMOTE" ] && msg_info "  远程: $VPN_REMOTE"
            echo ""
            echo "VPN 路由："
            ip route show dev tun0 2>/dev/null | head -10 | sed 's/^/  /'
        else
            msg_err "  未连接"
        fi
        echo ""

        echo "DNS 服务器："
        grep '^nameserver' /etc/resolv.conf 2>/dev/null | sed 's/^/  /' || echo "  无"
        echo ""

        echo "最近日志（最后 40 行）："
        echo "------------------------------------------------------------"
        if [ -f "$LOG_FILE" ]; then
            tail -n 40 "$LOG_FILE" | sed 's/^[^ ]* [^ ]* [^ ]* [^ ]* //'
        else
            echo "  日志文件尚未生成"
        fi

        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # 
    # 模式8：卸载 OpenVPN 客户端
    # 
    if [ "$MODE" = "8" ]; then
        msg_warn "将删除所有配置和日志！"
        printf "输入 YES 确认： "; read confirm
        [ "$confirm" != "YES" ] && continue

        $SERVICE_STOP 2>/dev/null || true
        $SERVICE_DISABLE 2>/dev/null || true
        rm -rf "${CONFIG_DIR:?}"/* 2>/dev/null || true
        rm -f "$LOG_FILE" 2>/dev/null || true
        $PKG_REMOVE openvpn 2>/dev/null || true

        audit "卸载 OpenVPN 客户端"
        msg_ok "卸载完成。"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─
    # 模式9：管理配置文件（多配置）
    # ─
    if [ "$MODE" = "9" ]; then
        echo "${BOLD}=== 配置文件管理 ===${RESET}"
        echo ""

        list_profiles

        if [ "$PROFILE_COUNT" -eq 0 ]; then
            msg_warn "暂无已保存的配置文件"
            msg_info "使用模式 2 导入 .ovpn 文件"
            printf "按回车返回菜单..."; read dummy; continue
        fi

        echo "已保存的配置文件："
        set -- $PROFILE_LIST
        _i=1
        while [ $# -gt 0 ]; do
            _active=""
            if [ -f "$CONFIG_FILE" ] && [ -f "$PROFILES_DIR/$1.ovpn" ]; then
                if cmp -s "$CONFIG_FILE" "$PROFILES_DIR/$1.ovpn" 2>/dev/null; then
                    _active=" ${GREEN}<- current${RESET}"
                fi
            fi
            _remote=$(grep -i '^remote ' "$PROFILES_DIR/$1.ovpn" 2>/dev/null | head -1 | awk '{print $2":"$3}')
            printf "  %d) %-20s %s%b\n" "$_i" "$1" "${_remote}" "$_active"
            shift
            _i=$((_i + 1))
        done
        echo ""
        msg_info "共 $PROFILE_COUNT 个配置文件"

        echo ""
        echo "操作："
        echo "  a) 激活某个配置为当前"
        echo "  d) 删除某个配置"
        echo "  r) 重命名某个配置"
        echo "  q) 返回主菜单"
        printf "选择操作： "; read _op

        case "$_op" in
            a)
                if select_profile "选择要激活的配置"; then
                    cp "$PROFILES_DIR/${SELECTED_PROFILE}.ovpn" "$CONFIG_FILE"
                    chmod 600 "$CONFIG_FILE"
                    audit "激活配置: $SELECTED_PROFILE"
                    msg_ok "已激活: $SELECTED_PROFILE"
                fi ;;
            d)
                if select_profile "选择要删除的配置"; then
                    printf "确认删除 %s？(y/n)： " "$SELECTED_PROFILE"; read _dc
                    if [ "$_dc" = "y" ]; then
                        rm -f "$PROFILES_DIR/${SELECTED_PROFILE}.ovpn"
                        audit "删除配置: $SELECTED_PROFILE"
                        msg_ok "已删除: $SELECTED_PROFILE"
                    fi
                fi ;;
            r)
                if select_profile "选择要重命名的配置"; then
                    printf "新名称： "; read _nn
                    if [ -n "$_nn" ]; then
                        mv "$PROFILES_DIR/${SELECTED_PROFILE}.ovpn" "$PROFILES_DIR/${_nn}.ovpn"
                        audit "重命名: $SELECTED_PROFILE -> $_nn"
                        msg_ok "已重命名: $SELECTED_PROFILE -> $_nn"
                    fi
                fi ;;
        esac

        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # 
    # 模式10：切换配置文件并连接
    # ─
    if [ "$MODE" = "10" ]; then
        echo "${BOLD}=== 切换配置并连接 ===${RESET}"
        echo ""

        if ! select_profile "选择要连接的配置"; then
            printf "按回车继续..."; read dummy; continue
        fi

        msg_info "正在切换到: $SELECTED_PROFILE"
        $SERVICE_STOP 2>/dev/null || true
        sleep 1

        cp "$PROFILES_DIR/${SELECTED_PROFILE}.ovpn" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"

        msg_info "正在连接..."
        $SERVICE_START >/dev/null 2>&1 || true

        SUCCESS=0
        i=1
        while [ "$i" -le 10 ]; do
            sleep 1
            printf "  检查 %d/10...\n" "$i"
            if check_vpn_connected; then
                get_vpn_info
                SUCCESS=1
                msg_ok "连接成功！VPN IP: ${VPN_IP:-未知}"
                break
            fi
            i=$((i + 1))
        done

        [ "$SUCCESS" -eq 0 ] && msg_err "连接失败，请检查日志"

        audit "切换配置并连接: $SELECTED_PROFILE success=$SUCCESS"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # 
    # 模式11：DNS 泄漏检测
    # ─
    if [ "$MODE" = "11" ]; then
        check_dns_leak
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─
    # 模式12：自动重连守护
    # 
    if [ "$MODE" = "12" ]; then
        echo "${BOLD}=== 自动重连守护 ===${RESET}"
        echo ""

        WATCHDOG_SCRIPT="/usr/local/bin/openvpn-watchdog.sh"
        WATCHDOG_INTERVAL=30

        if [ -f "$WATCHDOG_SCRIPT" ]; then
            msg_info "自动重连脚本已存在"
            cat "$WATCHDOG_SCRIPT"
            echo ""
            echo "1) 更新配置"
            echo "2) 删除自动重连"
            echo "3) 返回"
            printf "选择： "; read _wop
            case "$_wop" in
                2)
                    _running_pid=$(pgrep -f 'openvpn-watchdog' 2>/dev/null | head -1)
                    [ -n "$_running_pid" ] && kill "$_running_pid" 2>/dev/null || true
                    rm -f "$WATCHDOG_SCRIPT"
                    crontab -l 2>/dev/null | grep -v 'openvpn-watchdog' | crontab - 2>/dev/null || true
                    rm -f /etc/local.d/openvpn-watchdog.start 2>/dev/null
                    audit "删除自动重连守护"
                    msg_ok "已删除自动重连"
                    printf "按回车继续..."; read dummy; continue ;;
                3) continue ;;
            esac
        fi

        printf "检查间隔（秒，默认 30）： "; read _intv
        WATCHDOG_INTERVAL=${_intv:-30}

        printf "连续失败多少次后重启服务？（默认 3）： "; read _max
        WATCHDOG_MAX=${_max:-3}

        cat > "$WATCHDOG_SCRIPT" << WATCHEOF
#!/bin/sh
# OpenVPN 自动重连守护脚本
LOG="/var/log/openvpn-watchdog.log"
MAX_FAIL=$WATCHDOG_MAX
FAIL_COUNT=0

while true; do
    if ip link show tun0 >/dev/null 2>&1; then
        FAIL_COUNT=0
    else
        FAIL_COUNT=\$((FAIL_COUNT + 1))
        _ts=\$(date '+%Y-%m-%d %H:%M:%S')
        echo "[\$_ts] VPN down (\$FAIL_COUNT/$WATCHDOG_MAX)" >> "\$LOG"

        if [ "\$FAIL_COUNT" -ge "\$MAX_FAIL" ]; then
            echo "[\$_ts] Restarting OpenVPN" >> "\$LOG"
            $SERVICE_STOP 2>/dev/null || true
            sleep 2
            $SERVICE_START 2>/dev/null || true
            FAIL_COUNT=0
            sleep 10
            continue
        fi
    fi
    sleep $WATCHDOG_INTERVAL
done
WATCHEOF
        chmod +x "$WATCHDOG_SCRIPT"

        # 停止旧实例
        _running_pid=$(pgrep -f 'openvpn-watchdog' 2>/dev/null | head -1)
        [ -n "$_running_pid" ] && kill "$_running_pid" 2>/dev/null || true
        sleep 1

        # 后台启动
        nohup "$WATCHDOG_SCRIPT" >/dev/null 2>&1 &
        _new_pid=$!

        # 开机自启
        if [ "$OS" = "alpine" ]; then
            cat > /etc/local.d/openvpn-watchdog.start << WDEOF
#!/bin/sh
nohup $WATCHDOG_SCRIPT >/dev/null 2>&1 &
WDEOF
            chmod +x /etc/local.d/openvpn-watchdog.start
        else
            (crontab -l 2>/dev/null | grep -v 'openvpn-watchdog'; echo "@reboot nohup $WATCHDOG_SCRIPT >/dev/null 2>&1 &") | crontab - 2>/dev/null || true
        fi

        audit "配置自动重连: interval=${WATCHDOG_INTERVAL}s max_fail=$WATCHDOG_MAX pid=$_new_pid"
        msg_ok "自动重连守护已启动 (PID: $_new_pid)"
        msg_info "间隔: ${WATCHDOG_INTERVAL}秒  阈值: ${WATCHDOG_MAX}次失败后重启"
        msg_info "守护日志: /var/log/openvpn-watchdog.log"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─
    # 模式13：查看审计日志
    # ─
    if [ "$MODE" = "13" ]; then
        echo "${BOLD}=== 管理操作审计日志 ===${RESET}"
        echo ""

        if [ ! -f "$AUDIT_LOG" ]; then
            msg_warn "审计日志尚未生成"
            printf "按回车返回菜单..."; read dummy; continue
        fi

        printf "显示最近多少条？（默认 50）： "; read _n
        _n=${_n:-50}

        echo "------------------------------------------------------------"
        tail -n "$_n" "$AUDIT_LOG"
        echo "------------------------------------------------------------"
        _total=$(wc -l < "$AUDIT_LOG")
        msg_info "共 $_total 条记录，显示最近 $_n 条"

        printf "按回车返回主菜单..."; read dummy; continue
    fi

    msg_warn "无效选项"
    printf "按回车返回主菜单..."; read dummy
done
