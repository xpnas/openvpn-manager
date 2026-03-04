#!/bin/sh
# ═══════════════════════════════════════════════════════════════
# OpenVPN 服务端管理脚本 v2.0 - 兼容 Alpine & Debian/Ubuntu
# 功能增强版：
#   原有: 安装/添加客户端/端口放行/客户端配置/全局配置/卸载/删除客户端/重启/停止/开机启动
#   新增: UDP支持/查看客户端列表/服务状态/备份恢复/导出.ovpn/日志轮转/自定义子网/吊销列表/流量统计/彩色输出/审计日志/非交互模式
# POSIX 兼容 (ash/dash/bash)
# ═══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────
# 彩色输出函数
# ─────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1) GREEN=$(tput setaf 2) YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6) BOLD=$(tput bold) RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
fi

msg_ok()   { printf "%s[✓] %s%s\n" "${GREEN}" "$1" "${RESET}"; }
msg_err()  { printf "%s[✗] %s%s\n" "${RED}"   "$1" "${RESET}"; }
msg_warn() { printf "%s[!] %s%s\n" "${YELLOW}" "$1" "${RESET}"; }
msg_info() { printf "%s[i] %s%s\n" "${CYAN}"  "$1" "${RESET}"; }

# ─────────────────────────────────────────────────────────────
# 审计日志
# ─────────────────────────────────────────────────────────────
AUDIT_LOG="/var/log/openvpn-admin.log"
audit() {
    _ts=$(date '+%Y-%m-%d %H:%M:%S')
    _user=$(whoami)
    printf '[%s] user=%s action="%s"\n' "$_ts" "$_user" "$*" >> "$AUDIT_LOG" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Root 权限检查
# ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    msg_err "请以 root 用户运行此脚本"
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# POSIX 兼容的 sed -i 替代函数
# ─────────────────────────────────────────────────────────────
sed_inplace() {
    _sed_expr="$1"
    _sed_file="$2"
    _sed_tmp="${_sed_file}.sedtmp.$$"
    sed "$_sed_expr" "$_sed_file" > "$_sed_tmp" && mv "$_sed_tmp" "$_sed_file"
}

# ─────────────────────────────────────────────────────────────
# 获取客户端列表函数
# ─────────────────────────────────────────────────────────────
get_client_list() {
    CLIENTS=""
    CLIENT_COUNT=0
    if [ -d "$EASYRSA_DIR/pki/issued" ]; then
        for _crt_file in "$EASYRSA_DIR"/pki/issued/*.crt; do
            [ ! -f "$_crt_file" ] && continue
            _crt_name=$(basename "$_crt_file" .crt)
            [ "$_crt_name" = "server" ] && continue
            CLIENTS="$CLIENTS $_crt_name"
            CLIENT_COUNT=$((CLIENT_COUNT + 1))
        done
    fi
    CLIENTS=$(echo "$CLIENTS" | sed 's/^ //')
}

# ─────────────────────────────────────────────────────────────
# 选择客户端通用函数 (设置 SELECTED_CLIENT)
# ─────────────────────────────────────────────────────────────
select_client() {
    _prompt="${1:-请选择客户端}"
    get_client_list
    if [ "$CLIENT_COUNT" -eq 0 ]; then
        msg_warn "暂无客户端证书。请先添加客户端。"
        SELECTED_CLIENT=""
        return 1
    fi
    set -- $CLIENTS
    i=1
    while [ $# -gt 0 ]; do
        echo "  $i) $1"
        shift
        i=$((i + 1))
    done
    echo ""
    printf "%s（1-%s，q返回）： " "$_prompt" "$((i - 1))"
    read _sel
    [ "$_sel" = "q" ] || [ "$_sel" = "Q" ] && { SELECTED_CLIENT=""; return 1; }
    if ! echo "$_sel" | grep -qE '^[0-9]+$' || [ "$_sel" -lt 1 ] || [ "$_sel" -ge "$i" ]; then
        msg_err "无效选择"
        SELECTED_CLIENT=""
        return 1
    fi
    set -- $CLIENTS
    j=1
    while [ "$j" -lt "$_sel" ]; do shift; j=$((j + 1)); done
    SELECTED_CLIENT="$1"
    return 0
}

# ─────────────────────────────────────────────────────────────
# 获取公网 IPv4 地址（强制 IPv4，多源冗余）
# ─────────────────────────────────────────────────────────────
get_public_ipv4() {
    _ip=""
    # 方法1: 使用 curl -4 强制 IPv4
    for _url in ifconfig.me icanhazip.com api.ipify.org ip.sb ipinfo.io/ip; do
        _ip=$(curl -4 -s --max-time 5 "$_url" 2>/dev/null)
        # 验证是否为合法的 IPv4 地址
        if echo "$_ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            echo "$_ip"
            return 0
        fi
    done
    # 方法2: 从网卡获取（排除内网地址，取第一个公网 IPv4）
    _ip=$(ip -4 addr show scope global 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
    if [ -n "$_ip" ]; then
        echo "$_ip"
        return 0
    fi
    return 1
}

# ─────────────────────────────────────────────────────────────
# 检测系统类型并设置变量
# ─────────────────────────────────────────────────────────────
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
    CONFIG_FILE="/etc/openvpn/openvpn.conf"
    PERSIST_FILE="/etc/local.d/openvpn-nat.start"
    EASYRSA_DIR="/etc/openvpn/easy-rsa"
    USE_SYSTEMD=0
elif [ -f /etc/debian_version ] || grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
    OS="debian"
    PKG_INSTALL="apt install -y"
    PKG_REMOVE="apt purge -y"
    PKG_UPDATE="apt update"
    PERSIST_FILE="/etc/iptables.rules.v4"
    USE_SYSTEMD=1

    # 自动检测服务单元: openvpn-server@server (新版) vs openvpn@server (旧版)
    # 策略：
    #   1. 看哪个服务正在运行 (is-active)
    #   2. 看哪个服务已启用 (is-enabled)
    #   3. 看正在运行的 openvpn 进程使用哪个配置
    #   4. 看哪个配置文件存在
    SVC_UNIT=""
    CONFIG_FILE=""
    EASYRSA_DIR=""

    # 检查1: 哪个服务正在运行
    if systemctl is-active openvpn-server@server >/dev/null 2>&1; then
        SVC_UNIT="openvpn-server@server"
        CONFIG_FILE="/etc/openvpn/server/server.conf"
        EASYRSA_DIR="/etc/openvpn/server/easy-rsa"
    elif systemctl is-active openvpn@server >/dev/null 2>&1; then
        SVC_UNIT="openvpn@server"
        CONFIG_FILE="/etc/openvpn/server.conf"
        EASYRSA_DIR="/etc/openvpn/easy-rsa"
    fi

    # 检查2: 如果都没在运行，看哪个已启用
    if [ -z "$SVC_UNIT" ]; then
        if systemctl is-enabled openvpn-server@server >/dev/null 2>&1; then
            SVC_UNIT="openvpn-server@server"
            CONFIG_FILE="/etc/openvpn/server/server.conf"
            EASYRSA_DIR="/etc/openvpn/server/easy-rsa"
        elif systemctl is-enabled openvpn@server >/dev/null 2>&1; then
            SVC_UNIT="openvpn@server"
            CONFIG_FILE="/etc/openvpn/server.conf"
            EASYRSA_DIR="/etc/openvpn/easy-rsa"
        fi
    fi

    # 检查3: 如果都没启用，看进程在用哪个配置
    if [ -z "$SVC_UNIT" ]; then
        _running_cfg=$(pgrep -a openvpn 2>/dev/null | grep -- '--config' | head -1 | sed 's/.*--config[[:space:]]*//' | awk '{print $1}')
        if [ -n "$_running_cfg" ]; then
            case "$_running_cfg" in
                /etc/openvpn/server/*)
                    SVC_UNIT="openvpn-server@server"
                    CONFIG_FILE="$_running_cfg"
                    EASYRSA_DIR="/etc/openvpn/server/easy-rsa"
                    ;;
                *)
                    SVC_UNIT="openvpn@server"
                    CONFIG_FILE="$_running_cfg"
                    EASYRSA_DIR="/etc/openvpn/easy-rsa"
                    ;;
            esac
        fi
    fi

    # 检查4: 看 --cd 参数（有些启动方式用 --cd 而不是绝对路径）
    if [ -z "$SVC_UNIT" ]; then
        _running_cd=$(pgrep -a openvpn 2>/dev/null | grep -- '--cd' | head -1)
        if [ -n "$_running_cd" ]; then
            case "$_running_cd" in
                *--cd*/etc/openvpn/server*)
                    SVC_UNIT="openvpn-server@server"
                    CONFIG_FILE="/etc/openvpn/server/server.conf"
                    EASYRSA_DIR="/etc/openvpn/server/easy-rsa"
                    ;;
                *--cd*/etc/openvpn*)
                    SVC_UNIT="openvpn@server"
                    CONFIG_FILE="/etc/openvpn/server.conf"
                    EASYRSA_DIR="/etc/openvpn/easy-rsa"
                    ;;
            esac
        fi
    fi

    # 检查5: 最后兜底，看哪个配置文件实际存在
    if [ -z "$SVC_UNIT" ]; then
        if [ -f /etc/openvpn/server.conf ]; then
            SVC_UNIT="openvpn@server"
            CONFIG_FILE="/etc/openvpn/server.conf"
            EASYRSA_DIR="/etc/openvpn/easy-rsa"
        elif [ -f /etc/openvpn/server/server.conf ]; then
            SVC_UNIT="openvpn-server@server"
            CONFIG_FILE="/etc/openvpn/server/server.conf"
            EASYRSA_DIR="/etc/openvpn/server/easy-rsa"
        else
            # 彻底兜底
            SVC_UNIT="openvpn@server"
            CONFIG_FILE="/etc/openvpn/server.conf"
            EASYRSA_DIR="/etc/openvpn/easy-rsa"
        fi
    fi

    SERVICE_START="systemctl start $SVC_UNIT"
    SERVICE_STOP="systemctl stop $SVC_UNIT"
    SERVICE_RESTART="systemctl restart $SVC_UNIT"
    SERVICE_ENABLE="systemctl enable $SVC_UNIT"
    SERVICE_DISABLE="systemctl disable $SVC_UNIT"
else
    msg_err "不支持的系统！仅支持 Alpine Linux 或 Debian/Ubuntu"
    exit 1
fi

CCD_DIR="/etc/openvpn/ccd"
BACKUP_DIR="/root/openvpn-backups"

# 自动检测 status log 路径
STATUS_LOG=""
# 优先从配置文件中读取 status 指令
if [ -f "$CONFIG_FILE" ]; then
    _cfg_status=$(grep '^status ' "$CONFIG_FILE" | awk '{print $2}')
    [ -n "$_cfg_status" ] && STATUS_LOG="$_cfg_status"
fi
# 如果配置文件中没有，看正在运行的 openvpn 进程 --status 参数
if [ -z "$STATUS_LOG" ] || [ ! -f "$STATUS_LOG" ]; then
    _proc_status=$(pgrep -a openvpn 2>/dev/null | grep -- '--status' | head -1 | sed 's/.*--status[[:space:]]*//' | awk '{print $1}')
    if [ -n "$_proc_status" ] && [ -f "$_proc_status" ]; then
        STATUS_LOG="$_proc_status"
    fi
fi
# 如果仍没找到，检查常见路径
if [ -z "$STATUS_LOG" ] || [ ! -f "$STATUS_LOG" ]; then
    for _sl in \
        /run/openvpn-server/status-server.log \
        /run/openvpn/server.status \
        /etc/openvpn/openvpn-status.log \
        /etc/openvpn/server/openvpn-status.log \
        /var/log/openvpn-status.log \
        /run/openvpn/status-server.log; do
        if [ -f "$_sl" ]; then
            STATUS_LOG="$_sl"
            break
        fi
    done
fi
# 最终兜底默认值
[ -z "$STATUS_LOG" ] && STATUS_LOG="/etc/openvpn/openvpn-status.log"

# ─────────────────────────────────────────────────────────────
# CRL 自动检查：如果 server.conf 配置了 crl-verify 但 CRL 文件缺失
# ─────────────────────────────────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
    _crl_line=$(grep '^crl-verify ' "$CONFIG_FILE" 2>/dev/null | awk '{print $2}')
    if [ -n "$_crl_line" ]; then
        # 解析 CRL 路径
        case "$_crl_line" in
            /*) _crl_path="$_crl_line" ;;
            *)  _crl_path="$(dirname "$CONFIG_FILE")/$_crl_line" ;;
        esac
        if [ ! -f "$_crl_path" ]; then
            msg_warn "CRL 文件缺失: $_crl_path"
            msg_warn "服务器配置了 crl-verify 但找不到 CRL 文件，所有客户端连接将被拒绝！"
            # 尝试自动生成
            if [ -d "$EASYRSA_DIR" ] && [ -f "$EASYRSA_DIR/easyrsa" ]; then
                msg_info "正在自动生成 CRL..."
                _cwd=$(pwd)
                cd "$EASYRSA_DIR"
                if ./easyrsa gen-crl 2>/dev/null; then
                    cp pki/crl.pem "$_crl_path" 2>/dev/null
                    chmod 644 "$_crl_path" 2>/dev/null
                    if [ -f "$_crl_path" ]; then
                        msg_ok "CRL 已自动生成并复制到 $_crl_path"
                        msg_info "建议重启 OpenVPN 服务使其生效"
                    else
                        msg_err "CRL 生成成功但复制失败，请手动执行："
                        echo "  cp $EASYRSA_DIR/pki/crl.pem $_crl_path"
                    fi
                else
                    msg_err "CRL 自动生成失败，请手动执行："
                    echo "  cd $EASYRSA_DIR && ./easyrsa gen-crl"
                    echo "  cp pki/crl.pem $_crl_path"
                fi
                cd "$_cwd"
            else
                msg_err "未找到 easy-rsa 目录，无法自动生成 CRL"
                echo "  手动修复：生成 CRL 并复制到 $_crl_path"
                echo "  或从 server.conf 中移除 crl-verify 行（不推荐）"
            fi
            echo ""
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────
# 默认的中国 IP 绕过列表（48条，含完整常用段）
# ─────────────────────────────────────────────────────────────
DEFAULT_BYPASS_PUSH='push "route 1.0.0.0 255.0.0.0 net_gateway"
push "route 14.0.0.0 255.0.0.0 net_gateway"
push "route 27.0.0.0 255.0.0.0 net_gateway"
push "route 36.0.0.0 255.0.0.0 net_gateway"
push "route 39.0.0.0 255.0.0.0 net_gateway"
push "route 42.0.0.0 255.0.0.0 net_gateway"
push "route 43.0.0.0 255.0.0.0 net_gateway"
push "route 49.0.0.0 255.0.0.0 net_gateway"
push "route 58.0.0.0 255.0.0.0 net_gateway"
push "route 59.0.0.0 255.0.0.0 net_gateway"
push "route 60.0.0.0 255.0.0.0 net_gateway"
push "route 61.0.0.0 255.0.0.0 net_gateway"
push "route 101.0.0.0 255.0.0.0 net_gateway"
push "route 103.0.0.0 255.0.0.0 net_gateway"
push "route 106.0.0.0 255.0.0.0 net_gateway"
push "route 110.0.0.0 255.0.0.0 net_gateway"
push "route 111.0.0.0 255.0.0.0 net_gateway"
push "route 112.0.0.0 255.0.0.0 net_gateway"
push "route 113.0.0.0 255.0.0.0 net_gateway"
push "route 114.0.0.0 255.0.0.0 net_gateway"
push "route 115.0.0.0 255.0.0.0 net_gateway"
push "route 116.0.0.0 255.0.0.0 net_gateway"
push "route 117.0.0.0 255.0.0.0 net_gateway"
push "route 118.0.0.0 255.0.0.0 net_gateway"
push "route 119.0.0.0 255.0.0.0 net_gateway"
push "route 120.0.0.0 255.0.0.0 net_gateway"
push "route 121.0.0.0 255.0.0.0 net_gateway"
push "route 122.0.0.0 255.0.0.0 net_gateway"
push "route 123.0.0.0 255.0.0.0 net_gateway"
push "route 124.0.0.0 255.0.0.0 net_gateway"
push "route 125.0.0.0 255.0.0.0 net_gateway"
push "route 139.0.0.0 255.0.0.0 net_gateway"
push "route 140.0.0.0 255.0.0.0 net_gateway"
push "route 171.0.0.0 255.0.0.0 net_gateway"
push "route 175.0.0.0 255.0.0.0 net_gateway"
push "route 180.0.0.0 255.0.0.0 net_gateway"
push "route 182.0.0.0 255.0.0.0 net_gateway"
push "route 183.0.0.0 255.0.0.0 net_gateway"
push "route 202.0.0.0 255.0.0.0 net_gateway"
push "route 203.0.0.0 255.0.0.0 net_gateway"
push "route 210.0.0.0 255.0.0.0 net_gateway"
push "route 211.0.0.0 255.0.0.0 net_gateway"
push "route 218.0.0.0 255.0.0.0 net_gateway"
push "route 219.0.0.0 255.0.0.0 net_gateway"
push "route 220.0.0.0 255.0.0.0 net_gateway"
push "route 221.0.0.0 255.0.0.0 net_gateway"
push "route 222.0.0.0 255.0.0.0 net_gateway"
push "route 223.0.0.0 255.0.0.0 net_gateway"'

# ═══════════════════════════════════════════════════════════════
# 非交互模式支持
# 用法: ./script.sh --add-client NAME [--nopass] [--ip SERVER_IP]
#       ./script.sh --del-client NAME
#       ./script.sh --list-clients
#       ./script.sh --status
#       ./script.sh --backup
#       ./script.sh --export-client NAME
#       ./script.sh --restart
#       ./script.sh --stop
# ═══════════════════════════════════════════════════════════════
if [ $# -gt 0 ]; then
    case "$1" in
        --add-client)
            CLIENT_NAME="$2"
            [ -z "$CLIENT_NAME" ] && { msg_err "用法: $0 --add-client NAME [--nopass] [--ip SERVER_IP]"; exit 1; }
            if [ ! -d "$EASYRSA_DIR" ] || [ ! -f "$CONFIG_FILE" ]; then
                msg_err "服务端未安装"; exit 1
            fi
            cd "$EASYRSA_DIR"
            EXTRA="nopass"
            SERVER_IP=""
            shift 2
            while [ $# -gt 0 ]; do
                case "$1" in
                    --nopass) EXTRA="nopass" ;;
                    --pass) EXTRA="" ;;
                    --ip) SERVER_IP="$2"; shift ;;
                esac
                shift
            done
            [ -z "$SERVER_IP" ] && SERVER_IP=$(get_public_ipv4 || echo "YOUR_SERVER_IP")
            PORT=$(grep '^port ' "$CONFIG_FILE" | awk '{print $2}'); PORT=${PORT:-443}
            PROTO=$(grep '^proto ' "$CONFIG_FILE" | awk '{print $2}'); PROTO=${PROTO:-tcp}
            ./easyrsa build-client-full "$CLIENT_NAME" $EXTRA
            CIPHER=$(grep '^cipher ' "$CONFIG_FILE" | awk '{print $2}'); CIPHER=${CIPHER:-AES-256-GCM}
            AUTH=$(grep '^auth ' "$CONFIG_FILE" | awk '{print $2}'); AUTH=${AUTH:-SHA512}
            # 检测 tls-auth 还是 tls-crypt
            _tls_mode=""
            if grep -q '^tls-crypt ' "$CONFIG_FILE" 2>/dev/null; then
                _tls_mode="tls-crypt"
            elif grep -q '^tls-auth ' "$CONFIG_FILE" 2>/dev/null; then
                _tls_mode="tls-auth"
            fi
            _ta_key_file=$(grep "^${_tls_mode} " "$CONFIG_FILE" 2>/dev/null | awk '{print $2}')
            # 解析 ta.key 路径
            if [ -n "$_ta_key_file" ]; then
                case "$_ta_key_file" in
                    /*) ;; # 绝对路径
                    *) _ta_key_file="/etc/openvpn/$_ta_key_file" ;; # 相对路径
                esac
            fi

            OVPN_FILE="/etc/openvpn/client-${CLIENT_NAME}.ovpn"
            cat > "$OVPN_FILE" << EOF
client
dev tun
proto $PROTO
remote $SERVER_IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher $CIPHER
auth $AUTH
verb 3
EOF
            # 追加 tls-auth/tls-crypt 内联块
            if [ "$_tls_mode" = "tls-auth" ] && [ -f "$_ta_key_file" ]; then
                printf '\nkey-direction 1\n<tls-auth>\n' >> "$OVPN_FILE"
                cat "$_ta_key_file" >> "$OVPN_FILE"
                printf '</tls-auth>\n' >> "$OVPN_FILE"
            elif [ "$_tls_mode" = "tls-crypt" ] && [ -f "$_ta_key_file" ]; then
                printf '\n<tls-crypt>\n' >> "$OVPN_FILE"
                cat "$_ta_key_file" >> "$OVPN_FILE"
                printf '</tls-crypt>\n' >> "$OVPN_FILE"
            fi
            # 追加证书
            {
                printf '\n<ca>\n'; cat pki/ca.crt; printf '</ca>\n'
                printf '<cert>\n'; sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "pki/issued/${CLIENT_NAME}.crt"; printf '</cert>\n'
                printf '<key>\n'; sed -n '/BEGIN .*PRIVATE KEY/,/END .*PRIVATE KEY/p' "pki/private/${CLIENT_NAME}.key"; printf '</key>\n'
            } >> "$OVPN_FILE"
            chmod 600 "$OVPN_FILE"
            audit "非交互添加客户端: $CLIENT_NAME"
            msg_ok "客户端已生成: $OVPN_FILE"
            exit 0
            ;;
        --del-client)
            CLIENT_NAME="$2"
            [ -z "$CLIENT_NAME" ] && { msg_err "用法: $0 --del-client NAME"; exit 1; }
            cd "$EASYRSA_DIR"
            echo "yes" | ./easyrsa revoke "$CLIENT_NAME" 2>/dev/null || true
            ./easyrsa gen-crl
            cp pki/crl.pem /etc/openvpn/ 2>/dev/null || true
            rm -f "pki/issued/${CLIENT_NAME}.crt" "pki/private/${CLIENT_NAME}.key" \
                  "$CCD_DIR/$CLIENT_NAME" "/etc/openvpn/client-${CLIENT_NAME}.ovpn" 2>/dev/null
            audit "非交互删除客户端: $CLIENT_NAME"
            msg_ok "已删除客户端: $CLIENT_NAME"
            exit 0
            ;;
        --list-clients)
            get_client_list
            if [ "$CLIENT_COUNT" -eq 0 ]; then echo "暂无客户端"; else echo "$CLIENTS" | tr ' ' '\n'; fi
            exit 0
            ;;
        --status)
            if [ "$OS" = "alpine" ]; then
                rc-service openvpn status 2>/dev/null || echo "服务未运行"
            else
                systemctl status "$SVC_UNIT" --no-pager -l 2>/dev/null || echo "服务未运行"
            fi
            exit 0
            ;;
        --backup)
            mkdir -p "$BACKUP_DIR"
            _bk="$BACKUP_DIR/openvpn-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
            tar czf "$_bk" -C / etc/openvpn 2>/dev/null
            audit "非交互备份: $_bk"
            msg_ok "备份完成: $_bk"
            exit 0
            ;;
        --export-client)
            CLIENT_NAME="$2"
            [ -z "$CLIENT_NAME" ] && { msg_err "用法: $0 --export-client NAME"; exit 1; }
            OVPN_FILE="/etc/openvpn/client-${CLIENT_NAME}.ovpn"
            if [ -f "$OVPN_FILE" ]; then
                cat "$OVPN_FILE"
            else
                msg_err "未找到 $OVPN_FILE"
                exit 1
            fi
            exit 0
            ;;
        --restart)
            $SERVICE_RESTART; audit "非交互重启服务"; exit 0 ;;
        --stop)
            $SERVICE_STOP; audit "非交互停止服务"; exit 0 ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "非交互模式:"
            echo "  --add-client NAME [--nopass|--pass] [--ip IP]  添加客户端"
            echo "  --del-client NAME                              删除客户端"
            echo "  --list-clients                                 列出所有客户端"
            echo "  --export-client NAME                           导出客户端 .ovpn 到 stdout"
            echo "  --status                                       查看服务状态"
            echo "  --backup                                       备份配置"
            echo "  --restart                                      重启服务"
            echo "  --stop                                         停止服务"
            echo "  --help                                         显示帮助"
            echo ""
            echo "不带参数则进入交互式菜单。"
            exit 0
            ;;
        *)
            msg_err "未知选项: $1  (使用 --help 查看帮助)"
            exit 1
            ;;
    esac
fi

# ═══════════════════════════════════════════════════════════════
# 交互式主菜单
# ═══════════════════════════════════════════════════════════════
msg_info "检测到系统：$OS"
if [ "$OS" = "debian" ]; then
    msg_info "服务单元：$SVC_UNIT"
fi
msg_info "配置文件：$CONFIG_FILE"
msg_info "状态日志：$STATUS_LOG"
echo ""

while true; do
    clear

    if [ -f "$CONFIG_FILE" ]; then
        echo "${BOLD}=== OpenVPN 服务端管理 v2.0 ===${RESET}"
        echo ""
        echo " ${GREEN} 1)${RESET} 添加新客户端"
        echo " ${GREEN} 2)${RESET} 放行/检查 VPN 端口"
        echo " ${GREEN} 3)${RESET} 配置特定客户端（LAN + 固定IP + push）"
        echo " ${GREEN} 4)${RESET} 全局自定义配置（中国IP绕过、DNS、LAN）"
        echo " ${GREEN} 5)${RESET} 重新安装/覆盖服务端配置"
        echo " ${GREEN} 6)${RESET} 卸载 OpenVPN 和所有配置"
        echo " ${GREEN} 7)${RESET} 删除指定客户端"
        echo " ${GREEN} 8)${RESET} 重启 OpenVPN 服务"
        echo " ${GREEN} 9)${RESET} 停止 OpenVPN 服务"
        echo " ${GREEN}10)${RESET} 开机启动 OpenVPN 服务"
        echo " ${GREEN}11)${RESET} 关闭开机启动 OpenVPN 服务"
        echo " ${CYAN}12)${RESET} 查看所有客户端列表"
        echo " ${CYAN}13)${RESET} 查看服务运行状态 / 在线客户端"
        echo " ${CYAN}14)${RESET} 备份配置"
        echo " ${CYAN}15)${RESET} 恢复配置"
        echo " ${CYAN}16)${RESET} 重新导出客户端 .ovpn"
        echo " ${CYAN}17)${RESET} 配置日志轮转"
        echo " ${CYAN}18)${RESET} 查看吊销证书列表"
        echo " ${CYAN}19)${RESET} 查看客户端流量统计"
        echo " ${CYAN}20)${RESET} 查看审计日志"
        echo " ${RED} 0)${RESET} 退出脚本"
        echo ""
        printf "请选择操作（0~20，回车默认1）： "
        read mode_choice
        MODE=${mode_choice:-1}
    else
        echo "未检测到服务端配置，将引导安装。"
        MODE=5
    fi

    [ "$MODE" = "0" ] && { echo "已退出脚本。"; exit 0; }

    # ─────────────────────────────────────────────────────────────
    # 模式1：添加新客户端
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "1" ]; then
        if [ ! -d "$EASYRSA_DIR" ] || [ ! -f "$CONFIG_FILE" ]; then
            msg_err "服务端未正确安装，请先选择模式 5。"
            printf "按回车继续..."; read dummy; continue
        fi

        cd "$EASYRSA_DIR"

        PORT=$(grep '^port ' "$CONFIG_FILE" | awk '{print $2}'); PORT=${PORT:-443}
        PROTO=$(grep '^proto ' "$CONFIG_FILE" | awk '{print $2}'); PROTO=${PROTO:-tcp}
        SERVER_IP=$(get_public_ipv4 || echo "YOUR_SERVER_IP")

        msg_info "读取配置：协议 $PROTO，端口 $PORT，服务器 IP $SERVER_IP"
        printf "修改 IP？（回车保持）： "; read input_ip
        SERVER_IP=${input_ip:-$SERVER_IP}

        printf "新客户端名称（例如 work、iphone14）： "; read CLIENT_NAME
        if [ -z "$CLIENT_NAME" ]; then
            msg_err "必须输入名称"
            printf "按回车继续..."; read dummy; continue
        fi

        echo "1) 有密码   2) 无密码（nopass）"
        printf "选择（回车2）： "; read pass_choice
        if [ "${pass_choice:-2}" = "1" ]; then EXTRA=""; else EXTRA="nopass"; fi

        ./easyrsa build-client-full "$CLIENT_NAME" $EXTRA

        CIPHER=$(grep '^cipher ' "$CONFIG_FILE" | awk '{print $2}'); CIPHER=${CIPHER:-AES-256-GCM}
        AUTH=$(grep '^auth ' "$CONFIG_FILE" | awk '{print $2}'); AUTH=${AUTH:-SHA512}

        # 检测 tls-auth 还是 tls-crypt
        _tls_mode=""
        if grep -q '^tls-crypt ' "$CONFIG_FILE" 2>/dev/null; then
            _tls_mode="tls-crypt"
        elif grep -q '^tls-auth ' "$CONFIG_FILE" 2>/dev/null; then
            _tls_mode="tls-auth"
        fi
        _ta_key_file=$(grep "^${_tls_mode} " "$CONFIG_FILE" 2>/dev/null | awk '{print $2}')
        if [ -n "$_ta_key_file" ]; then
            case "$_ta_key_file" in /*) ;; *) _ta_key_file="/etc/openvpn/$_ta_key_file" ;; esac
        fi

        OVPN_FILE="/etc/openvpn/client-${CLIENT_NAME}.ovpn"
        cat > "$OVPN_FILE" << EOF
client
dev tun
proto $PROTO
remote $SERVER_IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher $CIPHER
auth $AUTH
verb 3
EOF
        # 追加 tls-auth/tls-crypt 内联块
        if [ "$_tls_mode" = "tls-auth" ] && [ -f "$_ta_key_file" ]; then
            printf '\nkey-direction 1\n<tls-auth>\n' >> "$OVPN_FILE"
            cat "$_ta_key_file" >> "$OVPN_FILE"
            printf '</tls-auth>\n' >> "$OVPN_FILE"
        elif [ "$_tls_mode" = "tls-crypt" ] && [ -f "$_ta_key_file" ]; then
            printf '\n<tls-crypt>\n' >> "$OVPN_FILE"
            cat "$_ta_key_file" >> "$OVPN_FILE"
            printf '</tls-crypt>\n' >> "$OVPN_FILE"
        fi
        # 追加证书
        {
            printf '\n<ca>\n'; cat pki/ca.crt; printf '</ca>\n'
            printf '<cert>\n'; sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "pki/issued/${CLIENT_NAME}.crt"; printf '</cert>\n'
            printf '<key>\n'; sed -n '/BEGIN .*PRIVATE KEY/,/END .*PRIVATE KEY/p' "pki/private/${CLIENT_NAME}.key"; printf '</key>\n'
        } >> "$OVPN_FILE"
        chmod 600 "$OVPN_FILE"
        audit "添加客户端: $CLIENT_NAME"
        msg_ok "客户端配置文件生成： $OVPN_FILE"

        printf "是否立即为 %s 配置（LAN、固定IP、push 等）？(y/n，回车 y)： " "$CLIENT_NAME"
        read configure_now
        configure_now=${configure_now:-y}

        if [ "$configure_now" = "y" ] || [ "$configure_now" = "Y" ]; then
            AUTO_CLIENT_NAME="$CLIENT_NAME"
            MODE=3
        else
            printf "按回车返回主菜单..."; read dummy; continue
        fi
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式3：特定客户端配置
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "3" ]; then
        if [ ! -d "$EASYRSA_DIR" ] || [ ! -f "$CONFIG_FILE" ]; then
            msg_err "服务端未正确安装。"
            printf "按回车返回菜单..."; read dummy; continue
        fi

        mkdir -p "$CCD_DIR"
        grep -q '^client-config-dir' "$CONFIG_FILE" || echo "client-config-dir $CCD_DIR" >> "$CONFIG_FILE"
        if ! grep -q '^client-to-client' "$CONFIG_FILE"; then
            printf "是否启用 client-to-client？(y/n，回车 y)： "; read c2c
            [ "${c2c:-y}" = "y" ] && echo "client-to-client" >> "$CONFIG_FILE"
        fi

        echo ""
        echo "客户端证书列表："

        if [ -n "$AUTO_CLIENT_NAME" ]; then
            CLIENT_NAME="$AUTO_CLIENT_NAME"
            msg_info "自动选择新添加的客户端：$CLIENT_NAME"
            AUTO_CLIENT_NAME=""
        else
            if ! select_client "请选择编号"; then
                printf "按回车继续..."; read dummy; continue
            fi
            CLIENT_NAME="$SELECTED_CLIENT"
            msg_info "已选择：$CLIENT_NAME"
        fi

        # 从配置文件读取 VPN 网段
        _vpn_net=$(grep '^server ' "$CONFIG_FILE" | awk '{print $2}')
        _vpn_mask=$(grep '^server ' "$CONFIG_FILE" | awk '{print $3}')
        _vpn_net=${_vpn_net:-10.8.0.0}
        _vpn_mask=${_vpn_mask:-255.255.255.0}
        # 生成示例 IP（网段前缀 + .x）
        _vpn_prefix=$(echo "$_vpn_net" | sed 's/\.[0-9]*$//')
        _vpn_example="${_vpn_prefix}.88"

        printf "固定 VPN IP（例如 %s，网段 %s/%s，回车跳过）： " "$_vpn_example" "$_vpn_net" "$_vpn_mask"; read FIXED_IP
        FIXED_MASK="$_vpn_mask"

        printf "客户端后面内网网段（例如 192.168.5.0，回车跳过）： "; read CLIENT_LAN_NET
        CLIENT_LAN_MASK="255.255.255.0"

        echo ""
        echo "针对 $CLIENT_NAME 的推送配置："
        printf "推送全局代理（redirect-gateway def1）？(y/n，回车 n)： "; read push_global
        push_global=${push_global:-n}

        echo ""
        echo "中国 IP 绕过（push route ... net_gateway）："
        echo "  1) 使用默认列表（39条）"
        echo "  2) 手动输入"
        echo "  3) 不添加"
        printf "选择（1~3，回车 3）： "; read bypass_choice
        bypass_choice=${bypass_choice:-3}

        BYPASS_PUSH=""
        if [ "$bypass_choice" = "1" ]; then
            BYPASS_PUSH="$DEFAULT_BYPASS_PUSH"
            msg_ok "已添加默认 39 条绕过段"
        elif [ "$bypass_choice" = "2" ]; then
            echo "请输入绕过段（格式：1.0.0.0 255.0.0.0，每行一个，空行结束）："
            while true; do
                printf "> "; read line
                [ -z "$line" ] && break
                BYPASS_PUSH="${BYPASS_PUSH}
push \"route $line net_gateway\""
            done
        fi

        printf "推送自定义 DNS（空格分隔，回车跳过）： "; read client_dns
        DNS_PUSH=""
        if [ -n "$client_dns" ]; then
            for dns in $client_dns; do
                DNS_PUSH="${DNS_PUSH}
push \"dhcp-option DNS $dns\""
            done
        fi

        CCD_FILE="$CCD_DIR/$CLIENT_NAME"
        > "$CCD_FILE"

        [ -n "$FIXED_IP" ] && echo "ifconfig-push $FIXED_IP $FIXED_MASK" >> "$CCD_FILE"

        if [ -n "$CLIENT_LAN_NET" ]; then
            if ! grep -q "route $CLIENT_LAN_NET" "$CONFIG_FILE"; then
                echo "route $CLIENT_LAN_NET $CLIENT_LAN_MASK" >> "$CONFIG_FILE"
                msg_ok "已添加全局 route $CLIENT_LAN_NET $CLIENT_LAN_MASK"
            fi
            echo "iroute $CLIENT_LAN_NET $CLIENT_LAN_MASK" >> "$CCD_FILE"
        fi

        # 网关角色：是否让该客户端作为默认互联网出口
        printf "是否将此客户端设为默认互联网出口网关（iroute 0.0.0.0，如 getway 角色）？(y/n，回车 n)： "; read is_gateway
        is_gateway=${is_gateway:-n}
        if [ "$is_gateway" = "y" ] || [ "$is_gateway" = "Y" ]; then
            echo "iroute 0.0.0.0 0.0.0.0" >> "$CCD_FILE"

            # 从 server.conf 读取 VPN 网段信息
            _srv_net=$(grep '^server ' "$CONFIG_FILE" | awk '{print $2}')
            _srv_mask=$(grep '^server ' "$CONFIG_FILE" | awk '{print $3}')
            case "${_srv_mask:-255.255.255.0}" in
                255.255.255.0) _srv_cidr="24" ;; 255.255.0.0) _srv_cidr="16" ;; *) _srv_cidr="24" ;;
            esac

            # 确保 mangle 标记规则存在
            iptables -t mangle -C PREROUTING -i tun0 ! -d ${_srv_net}/${_srv_cidr} -j MARK --set-mark 0x100 2>/dev/null || \
            iptables -t mangle -A PREROUTING -i tun0 ! -d ${_srv_net}/${_srv_cidr} -j MARK --set-mark 0x100

            # 确保 ip rule 存在
            ip rule add fwmark 0x100 lookup 100 priority 100 2>/dev/null || true

            # 确保路由表已注册
            if ! grep -q "^100 vpntunnel" /etc/iproute2/rt_tables 2>/dev/null; then
                echo "100 vpntunnel" >> /etc/iproute2/rt_tables
            fi

            # 如果 tun0 已存在则立即生效
            if ip link show tun0 >/dev/null 2>&1; then
                ip route replace default via "$VPN_IP" dev tun0 table 100 2>/dev/null || true
                msg_ok "策略路由已立即生效: table 100 default via $VPN_IP"
            fi

            # 更新 systemd override / Alpine local.d（持久化，重启后自动生效）
            if [ "$OS" = "alpine" ]; then
                cat > /etc/local.d/openvpn-policy-route.start << ALPEOF
#!/bin/sh
sleep 3
ip route replace default via $VPN_IP dev tun0 table 100 2>/dev/null || true
ALPEOF
                cat > /etc/local.d/openvpn-policy-route.stop << ALPEOF
#!/bin/sh
ip route flush table 100 2>/dev/null || true
ALPEOF
                chmod +x /etc/local.d/openvpn-policy-route.start /etc/local.d/openvpn-policy-route.stop
                msg_ok "Alpine 策略路由已更新: 网关 IP = $VPN_IP"
            else
                mkdir -p /etc/systemd/system/openvpn@server.service.d
                cat > /etc/systemd/system/openvpn@server.service.d/policy-route.conf << SYSEOF
[Service]
ExecStartPost=-/bin/sh -c 'sleep 2; ip route replace default via $VPN_IP dev tun0 table 100 || true'
ExecStopPost=-/bin/sh -c 'ip route flush table 100 || true'
SYSEOF
                systemctl daemon-reload
                msg_ok "systemd override 已更新: 网关 IP = $VPN_IP"
            fi

            # 持久化 iptables
            if [ "$OS" = "alpine" ]; then
                # Alpine: 追加到持久化文件 (如果不存在)
                if ! grep -q "mangle.*0x100" "$PERSIST_FILE" 2>/dev/null; then
                    echo "iptables -t mangle -A PREROUTING -i tun0 ! -d ${_srv_net}/${_srv_cidr} -j MARK --set-mark 0x100" >> "$PERSIST_FILE"
                    echo "ip rule add fwmark 0x100 lookup 100 priority 100 2>/dev/null || true" >> "$PERSIST_FILE"
                fi
            else
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi

            msg_ok "已设为网关角色：所有其他客户端的海外流量将通过此客户端出去"
            msg_info "安全策略路由: 仅 tun0 入站流量转发给网关，服务器自身流量不受影响"
        fi

        [ "$push_global" = "y" ] && echo "push \"redirect-gateway def1\"" >> "$CCD_FILE"

        # 如果启用了 redirect-gateway，询问是否推送内网路由
        if [ "$push_global" = "y" ]; then
            printf "推送内网路由（如 192.168.5.0/24 走 VPN，确保内网可达）？(输入网段，回车跳过)： "; read push_lan
            if [ -n "$push_lan" ]; then
                echo "push \"route $push_lan 255.255.255.0 vpn_gateway\"" >> "$CCD_FILE"
                msg_ok "已添加内网路由推送: $push_lan/24 via vpn_gateway"
            fi
        fi

        [ -n "$BYPASS_PUSH" ] && printf '%s\n' "$BYPASS_PUSH" >> "$CCD_FILE"
        [ -n "$DNS_PUSH" ] && printf '%s\n' "$DNS_PUSH" >> "$CCD_FILE"

        audit "配置客户端: $CLIENT_NAME"
        echo ""
        msg_ok "生成/更新完成：$CCD_FILE"
        cat "$CCD_FILE"
        echo ""
        msg_info "执行：$SERVICE_RESTART"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式2：端口放行
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "2" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            msg_err "服务端未安装，请先选择模式 5。"
            printf "按回车继续..."; read dummy; continue
        fi

        PORT=$(grep '^port ' "$CONFIG_FILE" | awk '{print $2}'); PORT=${PORT:-443}
        PROTO=$(grep '^proto ' "$CONFIG_FILE" | awk '{print $2}'); PROTO=${PROTO:-tcp}
        msg_info "当前监听端口：${PROTO} $PORT"

        printf "是否自动放行端口？输入 YES 确认： "; read confirm
        if [ "$confirm" = "YES" ]; then
            iptables -I INPUT -p "$PROTO" --dport "$PORT" -j ACCEPT

            if [ "$OS" = "alpine" ]; then
                mkdir -p /etc/local.d
                cat > /etc/local.d/openvpn-firewall.start << EOF
iptables -I INPUT -p $PROTO --dport $PORT -j ACCEPT
EOF
                chmod +x /etc/local.d/openvpn-firewall.start
            elif [ "$OS" = "debian" ]; then
                msg_info "建议安装 iptables-persistent 并运行 netfilter-persistent save"
            fi

            audit "放行端口: $PROTO $PORT"
            msg_ok "端口已放行。"
        fi

        echo ""
        echo "当前 INPUT 链相关规则："
        iptables -L INPUT -v -n | grep "$PORT" || echo "未找到相关规则"
        msg_warn "云厂商安全组仍需手动放行 ${PROTO} $PORT"
        echo ""
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式4：全局自定义配置
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "4" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            msg_err "服务端未安装。"
            printf "按回车返回菜单..."; read dummy; continue
        fi

        echo "${BOLD}=== 全局配置修改（影响所有客户端）===${RESET}"
        echo ""

        printf "是否修改中国IP绕过列表？(y/n)： "; read add_bypass
        if [ "$add_bypass" = "y" ] || [ "$add_bypass" = "Y" ]; then
            echo ""
            echo "1) 使用默认列表（39条）"
            echo "2) 手动输入新列表（清空旧的）"
            echo "3) 追加到现有"
            echo "4) 跳过"
            printf "选择（1~4，回车1）： "; read ch
            ch=${ch:-1}

            case $ch in
                1)
                    sed_inplace '/^push "route .* net_gateway"/d' "$CONFIG_FILE"
                    echo "$DEFAULT_BYPASS_PUSH" >> "$CONFIG_FILE"
                    msg_ok "已导入默认 39 条绕过段"
                    ;;
                2)
                    sed_inplace '/^push "route .* net_gateway"/d' "$CONFIG_FILE"
                    echo "请输入新段（格式 1.0.0.0 255.0.0.0，每行一个，空行结束）："
                    while true; do
                        printf "> "; read line
                        [ -z "$line" ] && break
                        echo "push \"route $line net_gateway\"" >> "$CONFIG_FILE"
                    done
                    ;;
                3)
                    echo "请输入追加段（同上格式）："
                    while true; do
                        printf "> "; read line
                        [ -z "$line" ] && break
                        echo "push \"route $line net_gateway\"" >> "$CONFIG_FILE"
                    done
                    ;;
                *) msg_info "跳过绕过修改" ;;
            esac
        fi

        printf "是否更新全局 DNS push？(y/n)： "; read dns_yn
        if [ "$dns_yn" = "y" ] || [ "$dns_yn" = "Y" ]; then
            printf "输入 DNS（空格分隔，例如 114.114.114.114 8.8.8.8）： "; read dns_list
            if [ -n "$dns_list" ]; then
                sed_inplace '/^push "dhcp-option DNS /d' "$CONFIG_FILE"
                for dns in $dns_list; do echo "push \"dhcp-option DNS $dns\"" >> "$CONFIG_FILE"; done
            fi
        fi

        printf "是否添加/更新全局 LAN route/push（例如 192.168.1.0/24，回车跳过）： "; read lan
        if [ -n "$lan" ]; then
            net=$(echo "$lan" | cut -d/ -f1)
            mask="255.255.255.0"
            sed_inplace "/^route $net /d" "$CONFIG_FILE"
            sed_inplace "/^push \"route $net /d" "$CONFIG_FILE"
            echo "route $net $mask" >> "$CONFIG_FILE"
            echo "push \"route $net $mask\"" >> "$CONFIG_FILE"
        fi

        audit "全局配置修改"
        msg_ok "全局配置更新完成。建议执行：$SERVICE_RESTART"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式5：安装/重新安装服务端（支持 TCP/UDP + 自定义子网掩码）
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "5" ]; then
        echo ""
        echo "${BOLD}=== 服务端安装 / 重新配置 ===${RESET}"
        echo ""

        # ── 协议选择 ──
        echo "协议选择："
        echo "1) TCP（更稳定，穿透性强）"
        echo "2) UDP（性能更好，延迟更低）"
        printf "选择（1~2，回车1）： "; read proto_choice
        if [ "${proto_choice:-1}" = "2" ]; then
            PROTO="udp"
        else
            PROTO="tcp"
        fi

        PORT=443
        printf "监听端口（默认 443）： "; read p
        PORT=${p:-443}

        VPN_NET="10.8.0.0"
        printf "VPN 网段（默认 10.8.0.0）： "; read n
        VPN_NET=${n:-10.8.0.0}

        # ── 子网掩码选择 ──
        echo ""
        echo "子网掩码选择："
        echo "1) 255.255.255.0  (/24 - 最多254客户端)"
        echo "2) 255.255.0.0    (/16 - 最多65534客户端)"
        echo "3) 自定义"
        printf "选择（1~3，回车1）： "; read mask_choice
        case "${mask_choice:-1}" in
            2) VPN_MASK="255.255.0.0" ;;
            3) printf "输入子网掩码: "; read VPN_MASK; VPN_MASK=${VPN_MASK:-255.255.255.0} ;;
            *) VPN_MASK="255.255.255.0" ;;
        esac

        echo ""
        echo "加密选项："
        echo "1) AES-256-GCM + SHA384"
        echo "2) AES-256-GCM + SHA512"
        echo "3) AES-128-GCM + SHA256"
        echo "4) CHACHA20-POLY1305 + SHA256"
        echo "5) 无加密（仅测试！）"
        printf "选择（1~5，回车2）： "; read enc
        enc=${enc:-2}

        case "$enc" in
            1) CIPHER="AES-256-GCM"; AUTH="SHA384";  TLS_MIN="1.2" ;;
            2) CIPHER="AES-256-GCM"; AUTH="SHA512";  TLS_MIN="1.2" ;;
            3) CIPHER="AES-128-GCM"; AUTH="SHA256";  TLS_MIN="1.2" ;;
            4) CIPHER="CHACHA20-POLY1305"; AUTH="SHA256"; TLS_MIN="1.2" ;;
            5)
                msg_warn "无加密模式！数据明文传输。"
                printf "输入 YES 确认： "; read confirm
                [ "$confirm" != "YES" ] && continue
                CIPHER="none"; AUTH="none"; TLS_MIN="1.2"
                ;;
            *) CIPHER="AES-256-GCM"; AUTH="SHA512"; TLS_MIN="1.2" ;;
        esac

        msg_info "配置预览：协议 $PROTO，端口 $PORT，网段 $VPN_NET/$VPN_MASK，$CIPHER + $AUTH"
        sleep 3

        # 安装依赖
        if [ "$OS" = "alpine" ]; then
            $PKG_INSTALL openvpn easy-rsa iptables openssl ca-certificates curl
        else
            $PKG_UPDATE
            $PKG_INSTALL openvpn easy-rsa iptables-persistent net-tools curl
        fi

        # 初始化 easy-rsa
        mkdir -p "$EASYRSA_DIR"
        if [ "$OS" = "alpine" ]; then
            cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR/" 2>/dev/null || true
        else
            if [ ! -d "$EASYRSA_DIR/pki" ]; then
                make-cadir "$EASYRSA_DIR" 2>/dev/null || cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR/" 2>/dev/null || true
            fi
        fi

        cd "$EASYRSA_DIR"

        cat > vars << EOF
set_var EASYRSA_REQ_COUNTRY    "US"
set_var EASYRSA_REQ_PROVINCE   "California"
set_var EASYRSA_REQ_CITY       "Los Angeles"
set_var EASYRSA_REQ_ORG        "MyVPN"
set_var EASYRSA_REQ_EMAIL      "admin@example.com"
set_var EASYRSA_KEY_SIZE       2048
set_var EASYRSA_CA_EXPIRE      3650
set_var EASYRSA_CERT_EXPIRE    3650
EOF

        ./easyrsa init-pki
        echo "yes" | ./easyrsa build-ca nopass
        ./easyrsa gen-dh
        ./easyrsa build-server-full server nopass
        openvpn --genkey secret ta.key
        ./easyrsa gen-crl

        cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/dh.pem ta.key /etc/openvpn/
        cp pki/crl.pem /etc/openvpn/ 2>/dev/null || true
        mkdir -p "$CCD_DIR"

        # 获取公网 IPv4
        SERVER_IP=$(get_public_ipv4)
        if [ -z "$SERVER_IP" ]; then
            printf "无法自动获取公网 IPv4，请手动输入： "; read SERVER_IP
        fi
        msg_info "服务器公网 IP: $SERVER_IP"

        # 根据系统类型设置用户组
        if [ "$OS" = "alpine" ]; then
            SRV_GROUP="nobody"
        else
            SRV_GROUP="nogroup"
        fi

        # 生成配置文件（含 status log 用于流量统计）
        cat > "$CONFIG_FILE" << EOF
port $PORT
proto $PROTO
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-auth ta.key 0
crl-verify crl.pem

topology subnet
server $VPN_NET $VPN_MASK
ifconfig-pool-persist ipp.txt

client-to-client
client-config-dir $CCD_DIR

keepalive 10 120
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
cipher $CIPHER
auth $AUTH
tls-version-min $TLS_MIN

status $STATUS_LOG 10

user nobody
group $SRV_GROUP
persist-key
persist-tun
verb 3
EOF

        # IP 转发
        if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
        sysctl -p 2>/dev/null || sysctl -w net.ipv4.ip_forward=1

        # 计算 CIDR 用于 iptables
        case "$VPN_MASK" in
            255.255.255.0) VPN_CIDR="24" ;;
            255.255.0.0)   VPN_CIDR="16" ;;
            255.0.0.0)     VPN_CIDR="8" ;;
            *)             VPN_CIDR="24" ;;
        esac

        OUT_IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
        # 架构说明: VPN Server 不做 NAT 出口！
        # 所有海外/互联网流量通过 tun0 转发给网关客户端 (getway)
        # getway 负责 NAT 出口到互联网和内网

        # NAT: VPN客户端互访经由客户端后面的子网（如通过 iroute 暴露的内网）
        # 使远端子网看到的源IP是其网关的内网IP，解决 DNS/服务 访问控制问题
        iptables -t nat -A POSTROUTING -s "${VPN_NET}/${VPN_CIDR}" -o tun0 -j MASQUERADE
        # FORWARD: tun0 内部双向转发（mobile/work <-> getway）
        iptables -I FORWARD -i tun0 -o tun0 -j ACCEPT
        # mangle: 标记 tun0 入站、目标非 VPN 子网的包 (用于策略路由)
        iptables -t mangle -A PREROUTING -i tun0 ! -d ${VPN_NET}/${VPN_CIDR} -j MARK --set-mark 0x100

        # 策略路由: 注册自定义路由表
        TABLE_ID=100
        if ! grep -q "^${TABLE_ID} vpntunnel" /etc/iproute2/rt_tables 2>/dev/null; then
            echo "${TABLE_ID} vpntunnel" >> /etc/iproute2/rt_tables
        fi
        ip rule add fwmark 0x100 lookup $TABLE_ID priority 100 2>/dev/null || true
        msg_info "策略路由规则已添加 (fwmark 0x100 → table vpntunnel)"

        # 询问网关客户端的 VPN IP（用于策略路由）
        echo ""
        printf "输入网关客户端 (getway) 的 VPN IP (回车默认 172.27.0.5)： "; read GATEWAY_CLIENT_IP
        GATEWAY_CLIENT_IP=${GATEWAY_CLIENT_IP:-172.27.0.5}
        msg_info "网关客户端 IP: $GATEWAY_CLIENT_IP"

        # 持久化
        if [ "$OS" = "alpine" ]; then
            cat > "$PERSIST_FILE" << EOF
#!/bin/sh
iptables -t nat -A POSTROUTING -s ${VPN_NET}/${VPN_CIDR} -o tun0 -j MASQUERADE
iptables -I FORWARD -i tun0 -o tun0 -j ACCEPT
iptables -t mangle -A PREROUTING -i tun0 ! -d ${VPN_NET}/${VPN_CIDR} -j MARK --set-mark 0x100
iptables -I INPUT -p $PROTO --dport $PORT -j ACCEPT
ip rule add fwmark 0x100 lookup 100 priority 100 2>/dev/null || true
EOF
            chmod +x "$PERSIST_FILE"
            # Alpine: 用 local.d 脚本在 OpenVPN 启动后添加路由表条目
            cat > /etc/local.d/openvpn-policy-route.start << ALPEOF
#!/bin/sh
# 等待 tun0 就绪后添加策略路由表条目
sleep 3
ip route replace default via $GATEWAY_CLIENT_IP dev tun0 table 100 2>/dev/null || true
ALPEOF
            cat > /etc/local.d/openvpn-policy-route.stop << ALPEOF
#!/bin/sh
ip route flush table 100 2>/dev/null || true
ALPEOF
            chmod +x /etc/local.d/openvpn-policy-route.start /etc/local.d/openvpn-policy-route.stop
            msg_info "Alpine 策略路由启停脚本已写入 /etc/local.d/"
        else
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            msg_info "已保存 iptables 规则到 /etc/iptables/rules.v4"

            # Debian/Ubuntu: 用 systemd override 在 OpenVPN 启停时管理路由表条目
            # ExecStartPost: 等待 tun0 就绪后添加路由表默认网关指向 getway
            # ExecStopPost:  清理路由表
            # 注意: 必须用 -/bin/sh -c 包装，前缀 - 表示忽略失败（防止杀死主进程）
            mkdir -p /etc/systemd/system/openvpn@server.service.d
            cat > /etc/systemd/system/openvpn@server.service.d/policy-route.conf << SYSEOF
[Service]
ExecStartPost=-/bin/sh -c 'sleep 2; ip route replace default via $GATEWAY_CLIENT_IP dev tun0 table 100 || true'
ExecStopPost=-/bin/sh -c 'ip route flush table 100 || true'
SYSEOF
            systemctl daemon-reload
            msg_info "systemd override 已创建: ExecStartPost/ExecStopPost 管理策略路由"
        fi

        $SERVICE_ENABLE 2>/dev/null || true
        $SERVICE_RESTART 2>/dev/null || true

        audit "安装服务端: proto=$PROTO port=$PORT net=$VPN_NET/$VPN_MASK cipher=$CIPHER"
        echo ""
        msg_ok "服务端安装完成。"
        msg_info "协议：$PROTO  端口：$PORT  IP：$SERVER_IP  网段：$VPN_NET/$VPN_MASK"
        msg_info "配置文件：$CONFIG_FILE"
        echo ""
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式6：卸载
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "6" ]; then
        echo "${BOLD}=== 卸载 OpenVPN ===${RESET}"
        msg_warn "这将删除所有证书、配置、规则等！"
        printf "输入 YES 确认卸载： "; read confirm
        [ "$confirm" != "YES" ] && continue

        $SERVICE_STOP 2>/dev/null || true
        $SERVICE_DISABLE 2>/dev/null || true

        # 从配置读取网段
        if [ -f "$CONFIG_FILE" ]; then
            UNINSTALL_VPN_NET=$(grep '^server ' "$CONFIG_FILE" | awk '{print $2}')
            UNINSTALL_VPN_MASK=$(grep '^server ' "$CONFIG_FILE" | awk '{print $3}')
        fi
        UNINSTALL_VPN_NET=${UNINSTALL_VPN_NET:-10.8.0.0}
        case "${UNINSTALL_VPN_MASK:-255.255.255.0}" in
            255.255.255.0) _cidr="24" ;; 255.255.0.0) _cidr="16" ;; *) _cidr="24" ;;
        esac
        iptables -t nat -D POSTROUTING -s "${UNINSTALL_VPN_NET}/${_cidr}" -j MASQUERADE 2>/dev/null || true
        # 清理策略路由相关规则
        iptables -t nat -D POSTROUTING -s "${UNINSTALL_VPN_NET}/${_cidr}" -o tun0 -j MASQUERADE 2>/dev/null || true
        iptables -t mangle -D PREROUTING -i tun0 ! -d ${UNINSTALL_VPN_NET}/${_cidr} -j MARK --set-mark 0x100 2>/dev/null || true
        iptables -D FORWARD -i tun0 -o tun0 -j ACCEPT 2>/dev/null || true
        ip rule del fwmark 0x100 lookup 100 2>/dev/null || true
        ip route flush table 100 2>/dev/null || true
        sed -i '/^100 vpntunnel$/d' /etc/iproute2/rt_tables 2>/dev/null || true

        # 清理 systemd override / Alpine local.d
        rm -rf /etc/systemd/system/openvpn@server.service.d 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        rm -f /etc/local.d/openvpn-policy-route.start /etc/local.d/openvpn-policy-route.stop 2>/dev/null || true

        rm -rf /etc/openvpn/* 2>/dev/null || true
        rm -rf "$EASYRSA_DIR" 2>/dev/null || true
        rm -f "$PERSIST_FILE" 2>/dev/null || true

        # 只卸载 openvpn 和 easy-rsa
        $PKG_REMOVE openvpn easy-rsa 2>/dev/null || true

        sed_inplace '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
        sysctl -p 2>/dev/null || true

        audit "卸载 OpenVPN"
        msg_ok "卸载完成。"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式7：删除指定客户端
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "7" ]; then
        if [ ! -d "$EASYRSA_DIR" ] || [ ! -f "$CONFIG_FILE" ]; then
            msg_err "服务端未正确安装。"
            printf "按回车返回菜单..."; read dummy; continue
        fi

        echo ""
        echo "当前客户端证书列表："
        if ! select_client "要删除的客户端编号"; then
            printf "按回车继续..."; read dummy; continue
        fi
        DEL_CLIENT="$SELECTED_CLIENT"
        msg_warn "将删除客户端：$DEL_CLIENT"

        printf "确认删除 %s？(y/n，回车 n)： " "$DEL_CLIENT"; read del_confirm
        del_confirm=${del_confirm:-n}
        if [ "$del_confirm" != "y" ] && [ "$del_confirm" != "Y" ]; then continue; fi

        cd "$EASYRSA_DIR"
        echo "yes" | ./easyrsa revoke "$DEL_CLIENT" 2>/dev/null || echo "撤销失败（可能已撤销）"
        ./easyrsa gen-crl
        cp pki/crl.pem /etc/openvpn/ 2>/dev/null || true
        rm -f "pki/issued/${DEL_CLIENT}.crt" "pki/private/${DEL_CLIENT}.key" \
              "$CCD_DIR/$DEL_CLIENT" "/etc/openvpn/client-${DEL_CLIENT}.ovpn" 2>/dev/null

        audit "删除客户端: $DEL_CLIENT"
        msg_ok "已删除 $DEL_CLIENT。CRL 已更新。建议执行：$SERVICE_RESTART"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式8：重启服务
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "8" ]; then
        msg_info "正在重启 OpenVPN 服务..."
        if $SERVICE_RESTART 2>&1; then
            sleep 2
            # 二次确认: 检查服务是否真正在运行
            if [ "$OS" = "alpine" ]; then
                if rc-service openvpn status >/dev/null 2>&1; then
                    audit "重启服务: 成功"
                    msg_ok "服务已重启。"
                else
                    audit "重启服务: 失败(进程未存活)"
                    msg_err "服务重启后未正常运行！"
                    msg_info "查看日志: cat /var/log/openvpn/openvpn.log"
                fi
            else
                if systemctl is-active --quiet openvpn@server; then
                    audit "重启服务: 成功"
                    msg_ok "服务已重启。"
                else
                    audit "重启服务: 失败(进程未存活)"
                    msg_err "服务重启后未正常运行！"
                    echo ""
                    msg_info "错误详情："
                    journalctl -u openvpn@server --no-pager -n 20 2>/dev/null | tail -20
                    echo ""
                    msg_info "配置检查："
                    openvpn --config "$CONFIG_FILE" --verb 0 2>&1 | head -5 || true
                fi
            fi
        else
            audit "重启服务: 命令失败"
            msg_err "重启命令执行失败！"
            if [ "$OS" != "alpine" ]; then
                echo ""
                msg_info "错误详情："
                journalctl -u openvpn@server --no-pager -n 20 2>/dev/null | tail -20
            fi
        fi
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式9：停止服务
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "9" ]; then
        msg_info "正在停止 OpenVPN 服务..."
        $SERVICE_STOP 2>/dev/null || true
        sleep 1
        # 确认服务已停止
        _still_running=0
        if [ "$OS" = "alpine" ]; then
            rc-service openvpn status >/dev/null 2>&1 && _still_running=1
        else
            systemctl is-active --quiet openvpn@server && _still_running=1
        fi
        if [ "$_still_running" -eq 1 ]; then
            msg_warn "服务仍在运行，尝试强制停止..."
            killall openvpn 2>/dev/null || true
            sleep 1
        fi
        audit "停止服务"
        msg_ok "服务已停止。"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式10：开机启动
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "10" ]; then
        $SERVICE_ENABLE
        audit "设置开机启动"
        msg_ok "已设置开机启动。"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式11：关闭开机启动
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "11" ]; then
        $SERVICE_DISABLE
        audit "关闭开机启动"
        msg_ok "已关闭开机启动。"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式12：查看所有客户端列表
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "12" ]; then
        echo "${BOLD}=== 客户端列表 ===${RESET}"
        echo ""
        get_client_list
        if [ "$CLIENT_COUNT" -eq 0 ]; then
            msg_warn "暂无客户端"
        else
            _idx=1
            for _c in $CLIENTS; do
                _status="${GREEN}有效${RESET}"
                # 检查是否已吊销
                if [ -f "$EASYRSA_DIR/pki/revoked/certs_by_serial" ] || [ -f "$EASYRSA_DIR/pki/index.txt" ]; then
                    if grep -q "^R.*CN=$_c\b" "$EASYRSA_DIR/pki/index.txt" 2>/dev/null; then
                        _status="${RED}已吊销${RESET}"
                    fi
                fi
                _has_ccd=""
                [ -f "$CCD_DIR/$_c" ] && _has_ccd=" [有CCD配置]"
                _has_ovpn=""
                [ -f "/etc/openvpn/client-${_c}.ovpn" ] && _has_ovpn=" [有.ovpn]"
                printf "  %2d) %-20s %b%s%s\n" "$_idx" "$_c" "$_status" "$_has_ccd" "$_has_ovpn"
                _idx=$((_idx + 1))
            done
            echo ""
            msg_info "共 $CLIENT_COUNT 个客户端证书"
        fi
        echo ""
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式13：查看服务运行状态 / 在线客户端
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "13" ]; then
        echo "${BOLD}=== 服务运行状态 ===${RESET}"
        echo ""

        # 1. 服务单元状态
        _svc_running=0
        if [ "$OS" = "alpine" ]; then
            if rc-service openvpn status >/dev/null 2>&1; then
                msg_ok "服务状态：运行中"
                _svc_running=1
            else
                msg_err "服务状态：未运行"
            fi
        else
            if systemctl is-active "$SVC_UNIT" >/dev/null 2>&1; then
                msg_ok "服务状态：运行中 ($SVC_UNIT)"
                _svc_running=1
            else
                msg_err "服务状态：未运行 ($SVC_UNIT)"
            fi
            _ts=$(systemctl show "$SVC_UNIT" --property=ActiveEnterTimestamp 2>/dev/null | sed 's/ActiveEnterTimestamp=//')
            [ -n "$_ts" ] && msg_info "上次启动: $_ts"
            if [ "$_svc_running" -eq 0 ]; then
                _exit_status=$(systemctl show "$SVC_UNIT" --property=ExecMainStatus 2>/dev/null | sed 's/ExecMainStatus=//')
                [ -n "$_exit_status" ] && [ "$_exit_status" != "0" ] && msg_warn "退出码: $_exit_status (异常退出)"
            fi
        fi

        # 2. 进程检测（即使 systemd 单元名不匹配也能发现）
        _ovpn_pids=$(pgrep -a openvpn 2>/dev/null | grep -v grep | grep -v 'manager\.sh' | grep '/usr/sbin/openvpn\|/usr/local/sbin/openvpn')
        if [ -n "$_ovpn_pids" ]; then
            if [ "$_svc_running" -eq 0 ]; then
                msg_warn "检测到 openvpn 进程在运行（但不在 systemd/openrc 管理下）："
            else
                msg_info "openvpn 进程："
            fi
            echo "$_ovpn_pids" | while IFS= read -r _pline; do
                printf "  PID %s\n" "$_pline"
            done
        elif [ "$_svc_running" -eq 0 ]; then
            msg_err "未检测到任何 openvpn 进程"
        fi

        echo ""

        # 3. 配置信息
        if [ -f "$CONFIG_FILE" ]; then
            _port=$(grep '^port ' "$CONFIG_FILE" | awk '{print $2}')
            _proto=$(grep '^proto ' "$CONFIG_FILE" | awk '{print $2}')
            _net=$(grep '^server ' "$CONFIG_FILE" | awk '{print $2, $3}')
            msg_info "监听: ${_proto:-tcp} ${_port:-443}  网段: ${_net:-未知}"

            # CRL 检查
            _crl_cfg=$(grep '^crl-verify ' "$CONFIG_FILE" | awk '{print $2}')
            if [ -n "$_crl_cfg" ]; then
                case "$_crl_cfg" in
                    /*) _crl_f="$_crl_cfg" ;;
                    *)  _crl_f="$(dirname "$CONFIG_FILE")/$_crl_cfg" ;;
                esac
                if [ -f "$_crl_f" ]; then
                    # 检查 CRL 是否过期
                    if command -v openssl >/dev/null 2>&1; then
                        _crl_next=$(openssl crl -in "$_crl_f" -noout -nextupdate 2>/dev/null | sed 's/nextUpdate=//')
                        if [ -n "$_crl_next" ]; then
                            _crl_exp=$(date -d "$_crl_next" +%s 2>/dev/null)
                            _now=$(date +%s)
                            if [ -n "$_crl_exp" ] && [ "$_now" -gt "$_crl_exp" ]; then
                                msg_err "CRL 已过期 (过期时间: $_crl_next)"
                                echo "  修复: cd $EASYRSA_DIR && ./easyrsa gen-crl && cp pki/crl.pem $_crl_f"
                            else
                                msg_ok "CRL 文件正常: $_crl_f"
                            fi
                        else
                            msg_ok "CRL 文件存在: $_crl_f"
                        fi
                    else
                        msg_ok "CRL 文件存在: $_crl_f"
                    fi
                else
                    msg_err "CRL 文件缺失: $_crl_f （所有客户端连接将被拒绝！）"
                    echo "  修复: cd $EASYRSA_DIR && ./easyrsa gen-crl && cp pki/crl.pem $_crl_f"
                fi
            fi

            # tls-auth / tls-crypt 检查
            _tls_diag=""
            if grep -q '^tls-crypt ' "$CONFIG_FILE" 2>/dev/null; then
                _tls_diag="tls-crypt"
                _ta_f=$(grep '^tls-crypt ' "$CONFIG_FILE" | awk '{print $2}')
            elif grep -q '^tls-auth ' "$CONFIG_FILE" 2>/dev/null; then
                _tls_diag="tls-auth"
                _ta_f=$(grep '^tls-auth ' "$CONFIG_FILE" | awk '{print $2}')
            fi
            if [ -n "$_tls_diag" ] && [ -n "$_ta_f" ]; then
                case "$_ta_f" in /*) ;; *) _ta_f="$(dirname "$CONFIG_FILE")/$_ta_f" ;; esac
                if [ -f "$_ta_f" ]; then
                    msg_ok "$_tls_diag 密钥正常: $_ta_f"
                else
                    msg_err "$_tls_diag 密钥缺失: $_ta_f"
                fi
            fi
        else
            msg_warn "配置文件不存在: $CONFIG_FILE"
        fi

        # 4. 端口监听检测
        _port=${_port:-443}
        _proto_short=$(echo "${_proto:-tcp}" | sed 's/[0-9-]//g')
        if command -v ss >/dev/null 2>&1; then
            _listen=$(ss -lnp 2>/dev/null | grep ":${_port} " | head -3)
        elif command -v netstat >/dev/null 2>&1; then
            _listen=$(netstat -lnp 2>/dev/null | grep ":${_port} " | head -3)
        else
            _listen=""
        fi
        if [ -n "$_listen" ]; then
            msg_ok "端口 ${_port} 正在监听"
            echo "$_listen" | sed 's/^/  /'
        else
            msg_err "端口 ${_port} 未监听"
        fi

        echo ""

        # 5. 在线客户端（从 status log 读取，兼容 v1 和 v2 格式）
        if [ -f "$STATUS_LOG" ]; then
            echo "${BOLD}在线客户端：${RESET}"
            msg_info "状态日志: $STATUS_LOG"
            echo "------------------------------------------------------------"

            _client_count=0
            # 检测格式版本: v2 的行以 HEADER, CLIENT_LIST, ROUTING_TABLE 等开头
            _is_v2=0
            grep -q '^HEADER' "$STATUS_LOG" 2>/dev/null && _is_v2=1

            if [ "$_is_v2" -eq 1 ]; then
                # ── status-version 2 格式 ──
                # CLIENT_LIST,CN,Real Address,Virtual Address,Virtual IPv6 Address,
                #   Bytes Received,Bytes Sent,Connected Since,Connected Since (time_t),
                #   Username,Client ID,Peer ID,Data Channel Cipher
                printf "  %-20s %-22s %-16s %s\n" "用户名" "来源地址" "VPN IP" "连接时间"
                echo "  ----"
                while IFS= read -r _line; do
                    case "$_line" in
                        CLIENT_LIST,*)
                            # 去掉 "CLIENT_LIST," 前缀
                            _data=$(echo "$_line" | cut -d',' -f2-)
                            _cn=$(echo "$_data" | cut -d',' -f1)
                            _real=$(echo "$_data" | cut -d',' -f2)
                            _vip=$(echo "$_data" | cut -d',' -f3)
                            _since=$(echo "$_data" | cut -d',' -f7)
                            # 跳过 UNDEF 条目
                            [ "$_cn" = "UNDEF" ] && continue
                            printf "  %-20s %-22s %-16s %s\n" "$_cn" "$_real" "${_vip:-—}" "$_since"
                            _client_count=$((_client_count + 1))
                            ;;
                    esac
                done < "$STATUS_LOG"
            else
                # ── status-version 1 格式（默认） ──
                # Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since
                printf "  %-20s %-22s %-16s %s\n" "用户名" "来源地址" "VPN IP" "连接时间"
                echo "  ----"
                _in_clients=0
                while IFS= read -r _line; do
                    case "$_in_clients" in
                        0) echo "$_line" | grep -q "^Common Name" && _in_clients=1 ;;
                        1)
                            echo "$_line" | grep -q "^ROUTING TABLE" && break
                            if [ -n "$_line" ]; then
                                _cn=$(echo "$_line" | cut -d',' -f1)
                                _real=$(echo "$_line" | cut -d',' -f2)
                                _since=$(echo "$_line" | cut -d',' -f5)
                                _vpnip=""
                                if [ -n "$_cn" ]; then
                                    # 从 ROUTING TABLE 中查找 VPN IP（排除子网 iroute 条目）
                                    _vpnip=$(awk -F',' -v cn="$_cn" '
                                        /^ROUTING TABLE/ { rt=1; next }
                                        /^GLOBAL STATS/  { rt=0; next }
                                        rt && $2==cn && $1 !~ /\// { print $1; exit }
                                    ' "$STATUS_LOG" 2>/dev/null)
                                fi
                                printf "  %-20s %-22s %-16s %s\n" "$_cn" "$_real" "${_vpnip:-—}" "$_since"
                                _client_count=$((_client_count + 1))
                            fi
                            ;;
                    esac
                done < "$STATUS_LOG"
            fi

            echo "------------------------------------------------------------"
            msg_info "在线客户端: ${_client_count} 个"

            # status log 更新时间
            if command -v stat >/dev/null 2>&1; then
                _log_mtime=$(stat -c '%Y' "$STATUS_LOG" 2>/dev/null || stat -f '%m' "$STATUS_LOG" 2>/dev/null)
                _now=$(date +%s)
                if [ -n "$_log_mtime" ] && [ -n "$_now" ]; then
                    _age=$((_now - _log_mtime))
                    if [ "$_age" -gt 60 ]; then
                        msg_warn "状态日志 ${_age} 秒未更新（可能服务已停止）"
                    else
                        msg_info "状态日志 ${_age} 秒前更新"
                    fi
                fi
            fi
        else
            msg_warn "状态日志不存在 ($STATUS_LOG)"
            msg_info "提示：配置文件中需要 'status $STATUS_LOG 10' 才能生成状态日志"
        fi

        # 6. 排查建议
        if [ "$_svc_running" -eq 0 ]; then
            echo ""
            echo "${BOLD}排查建议：${RESET}"
            if [ "$OS" = "debian" ]; then
                msg_info "1) 查看详细日志: journalctl -u $SVC_UNIT -n 50 --no-pager"
                msg_info "2) 手动启动测试: openvpn --config $CONFIG_FILE --verb 4"
                msg_info "3) 启动服务: systemctl start $SVC_UNIT"
            else
                msg_info "1) 查看日志: tail -50 /var/log/openvpn.log"
                msg_info "2) 手动启动测试: openvpn --config $CONFIG_FILE --verb 4"
            fi
            msg_info "当前检测到的服务单元: $SVC_UNIT"
            msg_info "当前配置文件: $CONFIG_FILE"
            msg_info "当前状态日志: $STATUS_LOG"
        fi

        echo ""
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式14：备份配置
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "14" ]; then
        echo "${BOLD}=== 备份配置 ===${RESET}"
        mkdir -p "$BACKUP_DIR"
        BACKUP_FILE="$BACKUP_DIR/openvpn-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar czf "$BACKUP_FILE" -C / etc/openvpn 2>/dev/null
        if [ $? -eq 0 ]; then
            _size=$(du -h "$BACKUP_FILE" | awk '{print $1}')
            audit "备份配置: $BACKUP_FILE"
            msg_ok "备份完成: $BACKUP_FILE (${_size})"
        else
            msg_err "备份失败"
        fi

        echo ""
        echo "历史备份列表："
        ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "  无历史备份"
        echo ""
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式15：恢复配置
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "15" ]; then
        echo "${BOLD}=== 恢复配置 ===${RESET}"
        echo ""
        echo "可用备份文件："

        _bk_count=0
        _bk_list=""
        if [ -d "$BACKUP_DIR" ]; then
            for _bk in "$BACKUP_DIR"/*.tar.gz; do
                [ ! -f "$_bk" ] && continue
                _bk_count=$((_bk_count + 1))
                _bk_list="$_bk_list $_bk"
                _bk_name=$(basename "$_bk")
                _bk_size=$(du -h "$_bk" | awk '{print $1}')
                printf "  %d) %s (%s)\n" "$_bk_count" "$_bk_name" "$_bk_size"
            done
        fi

        if [ "$_bk_count" -eq 0 ]; then
            msg_warn "无可用备份"
            printf "按回车返回菜单..."; read dummy; continue
        fi

        echo ""
        printf "选择要恢复的备份编号（q取消）： "; read _bk_sel
        [ "$_bk_sel" = "q" ] || [ "$_bk_sel" = "Q" ] && continue

        if ! echo "$_bk_sel" | grep -qE '^[0-9]+$' || [ "$_bk_sel" -lt 1 ] || [ "$_bk_sel" -gt "$_bk_count" ]; then
            msg_err "无效选择"; printf "按回车继续..."; read dummy; continue
        fi

        set -- $_bk_list
        _j=1
        while [ "$_j" -lt "$_bk_sel" ]; do shift; _j=$((_j + 1)); done
        RESTORE_FILE="$1"

        msg_warn "恢复将覆盖当前 /etc/openvpn 目录！"
        printf "输入 YES 确认恢复： "; read _rc
        if [ "$_rc" = "YES" ]; then
            $SERVICE_STOP 2>/dev/null || true
            rm -rf /etc/openvpn/* 2>/dev/null || true
            tar xzf "$RESTORE_FILE" -C / 2>/dev/null
            if [ $? -eq 0 ]; then
                audit "恢复配置: $RESTORE_FILE"
                msg_ok "恢复完成，建议重启服务"
            else
                msg_err "恢复失败"
            fi
        fi
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式16：重新导出客户端 .ovpn
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "16" ]; then
        echo "${BOLD}=== 重新导出客户端 .ovpn ===${RESET}"
        echo ""

        if [ ! -d "$EASYRSA_DIR" ] || [ ! -f "$CONFIG_FILE" ]; then
            msg_err "服务端未正确安装。"
            printf "按回车返回菜单..."; read dummy; continue
        fi

        if ! select_client "选择要导出的客户端"; then
            printf "按回车继续..."; read dummy; continue
        fi
        CLIENT_NAME="$SELECTED_CLIENT"

        cd "$EASYRSA_DIR"

        if [ ! -f "pki/issued/${CLIENT_NAME}.crt" ] || [ ! -f "pki/private/${CLIENT_NAME}.key" ]; then
            msg_err "找不到 $CLIENT_NAME 的证书或私钥"
            printf "按回车继续..."; read dummy; continue
        fi

        PORT=$(grep '^port ' "$CONFIG_FILE" | awk '{print $2}'); PORT=${PORT:-443}
        PROTO=$(grep '^proto ' "$CONFIG_FILE" | awk '{print $2}'); PROTO=${PROTO:-tcp}
        CIPHER=$(grep '^cipher ' "$CONFIG_FILE" | awk '{print $2}'); CIPHER=${CIPHER:-AES-256-GCM}
        AUTH=$(grep '^auth ' "$CONFIG_FILE" | awk '{print $2}'); AUTH=${AUTH:-SHA512}

        SERVER_IP=$(get_public_ipv4 || echo "YOUR_SERVER_IP")
        printf "服务器 IP（回车使用 %s）： " "$SERVER_IP"; read _ip
        SERVER_IP=${_ip:-$SERVER_IP}

        # 检测 tls-auth 还是 tls-crypt
        _tls_mode=""
        if grep -q '^tls-crypt ' "$CONFIG_FILE" 2>/dev/null; then
            _tls_mode="tls-crypt"
        elif grep -q '^tls-auth ' "$CONFIG_FILE" 2>/dev/null; then
            _tls_mode="tls-auth"
        fi
        _ta_key_file=$(grep "^${_tls_mode} " "$CONFIG_FILE" 2>/dev/null | awk '{print $2}')
        if [ -n "$_ta_key_file" ]; then
            case "$_ta_key_file" in /*) ;; *) _ta_key_file="/etc/openvpn/$_ta_key_file" ;; esac
        fi

        OVPN_FILE="/etc/openvpn/client-${CLIENT_NAME}.ovpn"
        cat > "$OVPN_FILE" << EOF
client
dev tun
proto $PROTO
remote $SERVER_IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher $CIPHER
auth $AUTH
verb 3
EOF
        # 追加 tls-auth/tls-crypt 内联块
        if [ "$_tls_mode" = "tls-auth" ] && [ -f "$_ta_key_file" ]; then
            printf '\nkey-direction 1\n<tls-auth>\n' >> "$OVPN_FILE"
            cat "$_ta_key_file" >> "$OVPN_FILE"
            printf '</tls-auth>\n' >> "$OVPN_FILE"
        elif [ "$_tls_mode" = "tls-crypt" ] && [ -f "$_ta_key_file" ]; then
            printf '\n<tls-crypt>\n' >> "$OVPN_FILE"
            cat "$_ta_key_file" >> "$OVPN_FILE"
            printf '</tls-crypt>\n' >> "$OVPN_FILE"
        fi
        # 追加证书
        {
            printf '\n<ca>\n'; cat pki/ca.crt; printf '</ca>\n'
            printf '<cert>\n'; sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "pki/issued/${CLIENT_NAME}.crt"; printf '</cert>\n'
            printf '<key>\n'; sed -n '/BEGIN .*PRIVATE KEY/,/END .*PRIVATE KEY/p' "pki/private/${CLIENT_NAME}.key"; printf '</key>\n'
        } >> "$OVPN_FILE"
        chmod 600 "$OVPN_FILE"
        audit "重新导出客户端: $CLIENT_NAME"
        msg_ok "已导出: $OVPN_FILE"
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式17：配置日志轮转
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "17" ]; then
        echo "${BOLD}=== 配置日志轮转 ===${RESET}"
        echo ""

        LOGROTATE_CONF="/etc/logrotate.d/openvpn"

        if [ -f "$LOGROTATE_CONF" ]; then
            msg_info "已存在日志轮转配置："
            cat "$LOGROTATE_CONF"
            echo ""
            printf "是否重新配置？(y/n，回车 n)： "; read _redo
            [ "${_redo:-n}" != "y" ] && { printf "按回车返回..."; read dummy; continue; }
        fi

        printf "保留多少天的日志？（默认 14）： "; read _days
        _days=${_days:-14}

        printf "单个日志最大大小？（默认 50M）： "; read _size
        _size=${_size:-50M}

        cat > "$LOGROTATE_CONF" << EOF
/var/log/openvpn*.log {
    daily
    rotate $_days
    compress
    delaycompress
    missingok
    notifempty
    size $_size
    create 0640 root root
    postrotate
        /bin/kill -HUP \$(cat /var/run/openvpn/server.pid 2>/dev/null) 2>/dev/null || true
    endscript
}
EOF

        # 同时配置审计日志轮转
        cat > "/etc/logrotate.d/openvpn-admin" << EOF
$AUDIT_LOG {
    monthly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

        audit "配置日志轮转: days=$_days size=$_size"
        msg_ok "日志轮转已配置"
        msg_info "服务日志: 每日轮转，保留 $_days 天，最大 $_size"
        msg_info "审计日志: 每月轮转，保留 12 个月"
        echo ""
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式18：查看吊销证书列表
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "18" ]; then
        echo "${BOLD}=== 吊销证书列表 ===${RESET}"
        echo ""

        INDEX_FILE="$EASYRSA_DIR/pki/index.txt"
        if [ ! -f "$INDEX_FILE" ]; then
            msg_warn "未找到证书索引文件"
            printf "按回车返回菜单..."; read dummy; continue
        fi

        echo "状态说明: V=有效  R=已吊销  E=已过期"
        echo "------------------------------------------------------------"

        _revoked=0
        _valid=0
        while IFS= read -r _line; do
            _flag=$(echo "$_line" | cut -c1)
            _cn=$(echo "$_line" | sed -n 's/.*CN=\([^/]*\).*/\1/p')
            [ -z "$_cn" ] && continue
            [ "$_cn" = "server" ] && continue

            case "$_flag" in
                V) _valid=$((_valid + 1)); printf "  ${GREEN}[V]${RESET} %s\n" "$_cn" ;;
                R) _revoked=$((_revoked + 1)); printf "  ${RED}[R]${RESET} %s\n" "$_cn" ;;
                E) printf "  ${YELLOW}[E]${RESET} %s\n" "$_cn" ;;
            esac
        done < "$INDEX_FILE"

        echo "------------------------------------------------------------"
        msg_info "有效: $_valid  已吊销: $_revoked"
        echo ""
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式19：查看客户端流量统计
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "19" ]; then
        echo "${BOLD}=== 客户端流量统计 ===${RESET}"
        echo ""

        if [ ! -f "$STATUS_LOG" ]; then
            msg_warn "状态日志不存在: $STATUS_LOG"
            msg_info "请确保配置文件中包含: status $STATUS_LOG 10"
            printf "按回车返回菜单..."; read dummy; continue
        fi

        # 人类可读流量的辅助函数
        _format_bytes() {
            _b="$1"
            if [ -z "$_b" ] || ! echo "$_b" | grep -qE '^[0-9]+$'; then
                echo "$_b"; return
            fi
            if [ "$_b" -gt 1073741824 ] 2>/dev/null; then
                echo "$((_b / 1073741824))GB"
            elif [ "$_b" -gt 1048576 ] 2>/dev/null; then
                echo "$((_b / 1048576))MB"
            elif [ "$_b" -gt 1024 ] 2>/dev/null; then
                echo "$((_b / 1024))KB"
            else
                echo "${_b}B"
            fi
        }

        # 解析 status log (兼容 v1 和 v2)
        echo "在线客户端流量："
        echo "------------------------------------------------------------"
        printf "  %-20s %-16s %-12s %-12s %s\n" "客户端" "VPN IP" "接收" "发送" "连接时间"
        echo "------------------------------------------------------------"

        _is_v2=0
        grep -q '^HEADER' "$STATUS_LOG" 2>/dev/null && _is_v2=1

        if [ "$_is_v2" -eq 1 ]; then
            # ── status-version 2 ──
            # CLIENT_LIST,CN,Real Address,Virtual Address,Virtual IPv6,Bytes Recv,Bytes Sent,Connected Since,...
            while IFS= read -r _line; do
                case "$_line" in
                    CLIENT_LIST,*)
                        _data=$(echo "$_line" | cut -d',' -f2-)
                        _name=$(echo "$_data" | cut -d',' -f1)
                        _real=$(echo "$_data" | cut -d',' -f2)
                        _vip=$(echo "$_data" | cut -d',' -f3)
                        _recv=$(echo "$_data" | cut -d',' -f5)
                        _sent=$(echo "$_data" | cut -d',' -f6)
                        _since=$(echo "$_data" | cut -d',' -f7)
                        [ "$_name" = "UNDEF" ] && continue
                        _recv_h=$(_format_bytes "$_recv")
                        _sent_h=$(_format_bytes "$_sent")
                        printf "  %-20s %-16s %-12s %-12s %s\n" "$_name" "${_vip:-—}" "↓${_recv_h}" "↑${_sent_h}" "$_since"
                        ;;
                esac
            done < "$STATUS_LOG"
        else
            # ── status-version 1 ──
            _in_list=0
            while IFS= read -r _line; do
                case "$_in_list" in
                    0)
                        echo "$_line" | grep -q "^Common Name" && _in_list=1
                        ;;
                    1)
                        echo "$_line" | grep -q "^ROUTING TABLE" && break
                        [ -z "$_line" ] && continue
                        _name=$(echo "$_line" | cut -d',' -f1)
                        _real=$(echo "$_line" | cut -d',' -f2)
                        _recv=$(echo "$_line" | cut -d',' -f3)
                        _sent=$(echo "$_line" | cut -d',' -f4)
                        _since=$(echo "$_line" | cut -d',' -f5)
                        _vpnip=""
                        if [ -n "$_name" ]; then
                            _vpnip=$(awk -F',' -v cn="$_name" '
                                /^ROUTING TABLE/ { rt=1; next }
                                /^GLOBAL STATS/  { rt=0; next }
                                rt && $2==cn && $1 !~ /\// { print $1; exit }
                            ' "$STATUS_LOG" 2>/dev/null)
                        fi
                        _recv_h=$(_format_bytes "$_recv")
                        _sent_h=$(_format_bytes "$_sent")
                        printf "  %-20s %-16s %-12s %-12s %s\n" "$_name" "${_vpnip:-$_real}" "↓${_recv_h}" "↑${_sent_h}" "$_since"
                        ;;
                esac
            done < "$STATUS_LOG"
        fi

        echo "------------------------------------------------------------"

        # 路由表
        echo ""
        echo "路由表（VPN IP 分配）："
        echo "------------------------------------------------------------"
        _in_route=0
        while IFS= read -r _line; do
            case "$_in_route" in
                0) echo "$_line" | grep -q "^Virtual Address" && _in_route=1 ;;
                1)
                    echo "$_line" | grep -q "^GLOBAL STATS" && break
                    [ -z "$_line" ] && continue
                    printf "  %s\n" "$_line"
                    ;;
            esac
        done < "$STATUS_LOG"
        echo "------------------------------------------------------------"

        echo ""
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式20：查看审计日志
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "20" ]; then
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

        echo ""
        printf "按回车返回主菜单..."; read dummy; continue
    fi

    msg_warn "无效选项"
    printf "按回车返回主菜单..."; read dummy
done
