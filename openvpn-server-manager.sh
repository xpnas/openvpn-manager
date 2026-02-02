#!/bin/sh
# OpenVPN TCP 管理脚本 - 兼容 Alpine & Debian/Ubuntu (单文件完整版)
# 功能：安装服务端 / 添加客户端 / 端口放行 / 特定客户端配置 / 全局配置 / 卸载 / 删除客户端 / 重启服务 / 停止服务 / 开机启动 / 关闭开机启动
# 自动检测系统类型并适配
# POSIX 兼容写法，适用于 ash / bash

set -e

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
    EASY_RSA_DIR="/etc/openvpn/easy-rsa"
    USE_SYSTEMD=0
elif [ -f /etc/debian_version ] || grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
    OS="debian"
    PKG_INSTALL="apt update && apt install -y"
    PKG_REMOVE="apt purge -y"
    PKG_UPDATE="apt update"
    SERVICE_START="systemctl start openvpn@server"
    SERVICE_STOP="systemctl stop openvpn@server"
    SERVICE_RESTART="systemctl restart openvpn@server"
    SERVICE_ENABLE="systemctl enable openvpn@server"
    SERVICE_DISABLE="systemctl disable openvpn@server"
    CONFIG_FILE="/etc/openvpn/server.conf"
    PERSIST_FILE="/etc/iptables.rules.v4"
    EASY_RSA_DIR="/etc/openvpn/easy-rsa"
    USE_SYSTEMD=1
else
    echo "不支持的系统！仅支持 Alpine Linux 或 Debian/Ubuntu"
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# 全局变量定义
# ─────────────────────────────────────────────────────────────
CCD_DIR="/etc/openvpn/ccd"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
echo "检测到系统：$OS"
echo "配置文件路径：$CONFIG_FILE"
echo ""

# ─────────────────────────────────────────────────────────────
# 默认的中国 IP 绕过列表（38条，只定义一次）
# ─────────────────────────────────────────────────────────────
DEFAULT_BYPASS_PUSH=$(cat << 'EOD'
push "route 1.0.0.0 255.0.0.0 net_gateway"
push "route 14.0.0.0 255.0.0.0 net_gateway"
push "route 36.0.0.0 255.0.0.0 net_gateway"
push "route 42.0.0.0 255.0.0.0 net_gateway"
push "route 43.0.0.0 255.0.0.0 net_gateway"
push "route 58.0.0.0 255.0.0.0 net_gateway"
push "route 59.0.0.0 255.0.0.0 net_gateway"
push "route 60.0.0.0 255.0.0.0 net_gateway"
push "route 61.0.0.0 255.0.0.0 net_gateway"
push "route 101.0.0.0 255.0.0.0 net_gateway"
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
push "route 171.0.0.0 255.0.0.0 net_gateway"
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
EOD
)

# ─────────────────────────────────────────────────────────────
# 主菜单循环
# ─────────────────────────────────────────────────────────────
while true; do
    clear

    if [ -f "$CONFIG_FILE" ]; then
        echo "OpenVPN 服务端已安装。"
        echo "1) 添加新客户端"
        echo "2) 放行/检查 VPN 端口（TCP）"
        echo "3) 配置特定客户端（LAN访问 + 固定IP + push）"
        echo "4) 全局自定义配置（中国IP绕过、DNS、LAN 等）"
        echo "5) 重新安装/覆盖服务端配置"
        echo "6) 卸载 OpenVPN 和所有配置"
        echo "7) 删除指定客户端"
        echo "8) 重启 OpenVPN 服务"
        echo "9) 停止 OpenVPN 服务"
        echo "10) 开机启动 OpenVPN 服务"
        echo "11) 关闭开机启动 OpenVPN 服务"
        echo "0) 退出脚本"
        echo ""
        read -p "请选择操作（0~11，回车默认1）： " mode_choice
        MODE=${mode_choice:-1}
    else
        echo "未检测到服务端配置，将引导安装。"
        MODE=5
    fi

    if [ "$MODE" = "0" ]; then
        echo "已退出脚本。"
        exit 0
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式1：添加新客户端 + 可立即配置
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "1" ]; then
        if [ ! -d "$EASYRSA_DIR" ] || [ ! -f "$CONFIG_FILE" ]; then
            echo "服务端未正确安装，请先选择模式 5。"
            read -p "按回车继续..."
            continue
        fi

        cd "$EASYRSA_DIR"

        PORT=$(grep '^port ' "$CONFIG_FILE" | awk '{print $2}' || echo "443")
        SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "YOUR_SERVER_IP")

        echo "读取配置：端口 $PORT，服务器 IP $SERVER_IP"
        read -p "修改 IP？（回车保持）： " input_ip
        SERVER_IP=${input_ip:-$SERVER_IP}

        read -p "新客户端名称（例如 work、iphone14）： " CLIENT_NAME
        [ -z "$CLIENT_NAME" ] && { echo "必须输入名称"; continue; }

        echo "1) 有密码   2) 无密码（nopass）"
        read -p "选择（回车2）： " pass_choice
        EXTRA=$([ "${pass_choice:-2}" = "1" ] && echo "" || echo "nopass")

        ./easyrsa build-client-full "$CLIENT_NAME" $EXTRA

        CIPHER=$(grep '^cipher ' "$CONFIG_FILE" | awk '{print $2}' || echo "AES-256-GCM")
        AUTH=$(grep '^auth ' "$CONFIG_FILE" | awk '{print $2}' || echo "SHA512")

        cat > "/etc/openvpn/client-${CLIENT_NAME}.ovpn" << EOF
client
dev tun
proto tcp
remote $SERVER_IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
tls-auth ta.key 1
cipher $CIPHER
auth $AUTH
verb 3

<ca>
$(cat pki/ca.crt)
</ca>
<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "pki/issued/${CLIENT_NAME}.crt")
</cert>
<key>
$(sed -n '/BEGIN .*PRIVATE KEY/,/END .*PRIVATE KEY/p' "pki/private/${CLIENT_NAME}.key")
</key>
<tls-auth>
$(cat /etc/openvpn/ta.key)
</tls-auth>
EOF

        echo ""
        echo "客户端配置文件生成： /etc/openvpn/client-${CLIENT_NAME}.ovpn"

        read -p "是否立即为 $CLIENT_NAME 配置（LAN、固定IP、push 等）？(y/n，回车 y)： " configure_now
        configure_now=${configure_now:-y}

        if [ "$configure_now" = "y" ] || [ "$configure_now" = "Y" ]; then
            AUTO_CLIENT_NAME="$CLIENT_NAME"
            MODE=3
        fi
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式3：特定客户端配置（支持自动进入）
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "3" ]; then
        if [ ! -d "$EASYRSA_DIR" ] || [ ! -f "$CONFIG_FILE" ]; then
            echo "错误：服务端未正确安装。"
            read -p "按回车返回菜单..."
            continue
        fi

        mkdir -p "$CCD_DIR"
        grep -q '^client-config-dir' "$CONFIG_FILE" || echo "client-config-dir $CCD_DIR" >> "$CONFIG_FILE"
        grep -q '^client-to-client' "$CONFIG_FILE" || {
            read -p "是否启用 client-to-client？(y/n，回车 y)： " c2c
            [ "${c2c:-y}" = "y" ] && echo "client-to-client" >> "$CONFIG_FILE"
        }

        echo ""
        echo "客户端证书列表："

        CLIENTS=""
        count=0
        while IFS= read -r file; do
            [ -n "$file" ] && {
                CLIENTS="$CLIENTS $file"
                count=$((count + 1))
            }
        done < <(ls -1 "$EASYRSA_DIR"/pki/issued/ 2>/dev/null | grep -v '^server\.crt$' | sed 's/\.crt$//')

        if [ $count -eq 0 ]; then
            echo "暂无客户端证书。请先使用模式 1 添加。"
            read -p "按回车返回菜单..."
            continue
        fi

        if [ -n "$AUTO_CLIENT_NAME" ]; then
            CLIENT_NAME="$AUTO_CLIENT_NAME"
            echo "自动选择新添加的客户端：$CLIENT_NAME"
            unset AUTO_CLIENT_NAME
        else
            set -- $CLIENTS
            i=1
            while [ $# -gt 0 ]; do
                echo "  $i) $1"
                shift
                i=$((i + 1))
            done
            echo ""

            read -p "请选择编号（1-$((i-1))，q返回菜单）： " choice
            [ "$choice" = "q" ] || [ "$choice" = "Q" ] && continue

            if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -ge $i ]; then
                echo "无效选择"
                continue
            fi

            set -- $CLIENTS
            j=1
            while [ $j -lt "$choice" ]; do
                shift
                j=$((j + 1))
            done
            CLIENT_NAME="$1"
            echo "已选择：$CLIENT_NAME"
        fi

        read -p "固定 VPN IP（例如 10.10.0.88，回车跳过）： " FIXED_IP
        FIXED_MASK="255.255.255.0"

        read -p "客户端后面内网网段（例如 192.168.5.0，回车跳过）： " CLIENT_LAN_NET
        CLIENT_LAN_MASK="255.255.255.0"

        echo ""
        echo "针对 $CLIENT_NAME 的推送配置："
        read -p "推送全局代理（redirect-gateway def1）？(y/n，回车 n)： " push_global
        push_global=${push_global:-n}

        echo ""
        echo "中国 IP 绕过（push route ... net_gateway）："
        echo "  1) 使用默认列表（38条）"
        echo "  2) 手动输入"
        echo "  3) 不添加"
        read -p "选择（1~3，回车 3）： " bypass_choice
        bypass_choice=${bypass_choice:-3}

        BYPASS_PUSH=""
        if [ "$bypass_choice" = "1" ]; then
            BYPASS_PUSH="$DEFAULT_BYPASS_PUSH"
            echo "已添加默认 38 条绕过段（仅推送给此客户端）"
        elif [ "$bypass_choice" = "2" ]; then
            echo "请输入绕过段（格式：1.0.0.0 255.0.0.0，每行一个，空行结束）："
            while read -p "> " line; do
                [ -z "$line" ] && break
                BYPASS_PUSH="$BYPASS_PUSH\npush \"route $line net_gateway\""
            done
        fi

        read -p "推送自定义 DNS（空格分隔，回车跳过）： " client_dns
        DNS_PUSH=""
        [ -n "$client_dns" ] && for dns in $client_dns; do DNS_PUSH="$DNS_PUSH\npush \"dhcp-option DNS $dns\""; done

        CCD_FILE="$CCD_DIR/$CLIENT_NAME"
        > "$CCD_FILE"

        [ -n "$FIXED_IP" ] && echo "ifconfig-push $FIXED_IP $FIXED_MASK" >> "$CCD_FILE"

        if [ -n "$CLIENT_LAN_NET" ]; then
            grep -q "route $CLIENT_LAN_NET" "$CONFIG_FILE" || {
                echo "route $CLIENT_LAN_NET $CLIENT_LAN_MASK" >> "$CONFIG_FILE"
                echo "已添加全局 route $CLIENT_LAN_NET $CLIENT_LAN_MASK"
            }
            echo "iroute $CLIENT_LAN_NET $CLIENT_LAN_MASK" >> "$CCD_FILE"
        fi

        [ "$push_global" = "y" ] && echo "push \"redirect-gateway def1\"" >> "$CCD_FILE"
        echo -e "$BYPASS_PUSH" >> "$CCD_FILE"
        echo -e "$DNS_PUSH" >> "$CCD_FILE"

        echo ""
        echo "生成/更新完成：$CCD_FILE"
        cat "$CCD_FILE"
        echo ""
        echo "客户端侧需开启 IP 转发 + NAT（如需服务器访问其 LAN）"
        echo "执行：$SERVICE_RESTART"
        echo ""
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式2：端口放行
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "2" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "服务端未安装，请先选择模式 5。"
            read -p "按回车继续..."
            continue
        fi

        PORT=$(grep '^port ' "$CONFIG_FILE" | awk '{print $2}' || echo "443")
        echo "当前监听端口：TCP $PORT"

        read -p "是否自动放行端口？输入 YES 确认： " confirm
        if [ "$confirm" = "YES" ]; then
            iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT

            if [ "$OS" = "alpine" ]; then
                mkdir -p /etc/local.d
                cat > /etc/local.d/openvpn-firewall.start << EOF
iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
EOF
                chmod +x /etc/local.d/openvpn-firewall.start
            elif [ "$OS" = "debian" ]; then
                echo "请安装 iptables-persistent 并保存规则："
                echo "apt install iptables-persistent"
                echo "netfilter-persistent save"
            fi

            echo "端口已放行。"
        fi

        echo ""
        echo "当前 INPUT 链相关规则："
        iptables -L INPUT -v -n | grep "$PORT" || echo "未找到相关规则"
        echo "云厂商安全组仍需手动放行 TCP $PORT"
        echo ""
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式4：全局自定义配置
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "4" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "服务端未安装。"
            read -p "按回车返回菜单..."
            continue
        fi

        echo "=== 全局配置修改（影响所有客户端）==="
        echo ""

        read -p "是否修改中国IP绕过列表？(y/n)： " add_bypass
        if [ "$add_bypass" = "y" ] || [ "$add_bypass" = "Y" ]; then
            echo ""
            echo "1) 使用默认列表（38条）"
            echo "2) 手动输入新列表（清空旧的）"
            echo "3) 追加到现有"
            echo "4) 跳过"
            read -p "选择（1~4，回车1）： " ch
            ch=${ch:-1}

            case $ch in
                1)
                    sed -i '/^push "route .* net_gateway"/d' "$CONFIG_FILE"
                    echo "$DEFAULT_BYPASS_PUSH" >> "$CONFIG_FILE"
                    echo "已导入默认 38 条绕过段"
                    ;;
                2)
                    sed -i '/^push "route .* net_gateway"/d' "$CONFIG_FILE"
                    echo "请输入新段（格式 1.0.0.0 255.0.0.0，每行一个，空行结束）："
                    while read -p "> " line; do
                        [ -z "$line" ] && break
                        echo "push \"route $line net_gateway\"" >> "$CONFIG_FILE"
                    done
                    ;;
                3)
                    echo "请输入追加段（同上格式）："
                    while read -p "> " line; do
                        [ -z "$line" ] && break
                        echo "push \"route $line net_gateway\"" >> "$CONFIG_FILE"
                    done
                    ;;
                *) echo "跳过绕过修改" ;;
            esac
        fi

        read -p "是否更新全局 DNS push？(y/n)： " dns_yn
        if [ "$dns_yn" = "y" ] || [ "$dns_yn" = "Y" ]; then
            read -p "输入 DNS（空格分隔，例如 114.114.114.114 8.8.8.8）： " dns_list
            [ -n "$dns_list" ] && {
                sed -i '/^push "dhcp-option DNS /d' "$CONFIG_FILE"
                for dns in $dns_list; do echo "push \"dhcp-option DNS $dns\"" >> "$CONFIG_FILE"; done
            }
        fi

        read -p "是否添加/更新全局 LAN route/push（例如 192.168.1.0/24，回车跳过）： " lan
        if [ -n "$lan" ]; then
            net=$(echo "$lan" | cut -d/ -f1)
            mask="255.255.255.0"
            sed -i "/^route $net /d" "$CONFIG_FILE"
            sed -i "/^push \"route $net /d" "$CONFIG_FILE"
            echo "route $net $mask" >> "$CONFIG_FILE"
            echo "push \"route $net $mask\"" >> "$CONFIG_FILE"
        fi

        echo ""
        echo "全局配置更新完成。"
        echo "执行：$SERVICE_RESTART"
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式5：安装/重新安装服务端
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "5" ]; then
        echo ""
        echo "=== 服务端安装 / 重新配置 ==="
        echo ""

        PORT=443
        read -p "监听端口（默认 443）： " p
        PORT=${p:-443}

        VPN_NET="10.8.0.0"
        read -p "VPN 网段（默认 10.8.0.0）： " n
        VPN_NET=${n:-10.8.0.0}

        echo ""
        echo "加密选项："
        echo "1) AES-256-GCM + SHA384"
        echo "2) AES-256-GCM + SHA512"
        echo "3) AES-128-GCM + SHA256"
        echo "4) CHACHA20-POLY1305 + SHA256"
        echo "5) 无加密（仅测试！）"
        read -p "选择（1~5，回车2）： " enc
        enc=${enc:-2}

        case "$enc" in
            1) CIPHER="AES-256-GCM"; AUTH="SHA384";  TLS_MIN="1.2" ;;
            2) CIPHER="AES-256-GCM"; AUTH="SHA512";  TLS_MIN="1.2" ;;
            3) CIPHER="AES-128-GCM"; AUTH="SHA256";  TLS_MIN="1.2" ;;
            4) CIPHER="CHACHA20-POLY1305"; AUTH="SHA256"; TLS_MIN="1.2" ;;
            5)
                echo "警告：无加密模式！数据明文传输。"
                read -p "输入 YES 确认： " confirm
                [ "$confirm" != "YES" ] && continue
                CIPHER="none"; AUTH="none"; TLS_MIN="1.2"
                ;;
            *)
                CIPHER="AES-256-GCM"; AUTH="SHA512"; TLS_MIN="1.2"
                ;;
        esac

        echo "配置预览：端口 $PORT，网段 $VPN_NET/24，$CIPHER + $AUTH"
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
            # Debian/Ubuntu 通常需要手动初始化或复制
            if [ ! -d "$EASYRSA_DIR/pki" ]; then
                make-cadir "$EASYRSA_DIR"
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
        SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        [ -z "$SERVER_IP" ] && read -p "无法获取公网IP，请手动输入：" SERVER_IP

        cat > "$CONFIG_FILE" << EOF
port $PORT
proto tcp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-auth ta.key 0
crl-verify crl.pem

topology subnet
server $VPN_NET 255.255.255.0
ifconfig-pool-persist ipp.txt

client-to-client
client-config-dir $CCD_DIR

keepalive 10 120
cipher $CIPHER
auth $AUTH
tls-version-min $TLS_MIN

user nobody
group nogroup
persist-key
persist-tun
verb 3
EOF

        # IP 转发
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p

        # NAT
        OUT_IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
        iptables -t nat -A POSTROUTING -s ${VPN_NET}/24 -o "$OUT_IFACE" -j MASQUERADE

        # 持久化
        if [ "$OS" = "alpine" ]; then
            cat > "$PERSIST_FILE" << EOF
#!/bin/sh
iptables -t nat -A POSTROUTING -s ${VPN_NET}/24 -o $OUT_IFACE -j MASQUERADE
iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
EOF
            chmod +x "$PERSIST_FILE"
        else
            iptables-save > /etc/iptables/rules.v4
            echo "已保存 iptables 规则到 /etc/iptables/rules.v4"
            echo "请确保 iptables-persistent 已安装，并运行：netfilter-persistent save"
        fi

        # 启动服务
        $SERVICE_ENABLE
        $SERVICE_RESTART

        echo ""
        echo "服务端安装完成。"
        echo "端口：$PORT    IP：$SERVER_IP"
        echo "配置文件：$CONFIG_FILE"
        echo ""
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式6：卸载
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "6" ]; then
        echo "=== 卸载 OpenVPN ==="
        echo "警告：这将删除所有证书、配置、规则等！"
        read -p "输入 YES 确认卸载： " confirm
        if [ "$confirm" != "YES" ]; then
            continue
        fi

        $SERVICE_STOP 2>/dev/null || true
        $SERVICE_DISABLE 2>/dev/null || true

        iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -j MASQUERADE 2>/dev/null || true

        rm -rf /etc/openvpn/* "$EASYRSA_DIR" 2>/dev/null
        rm -f "$PERSIST_FILE" 2>/dev/null

        $PKG_REMOVE openvpn easy-rsa iptables iptables-persistent openssl ca-certificates curl 2>/dev/null || true

        sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
        sysctl -p 2>/dev/null || true

        echo "卸载完成。"
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式7：删除指定客户端
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "7" ]; then
        if [ ! -d "$EASYRSA_DIR" ] || [ ! -f "$CONFIG_FILE" ]; then
            echo "服务端未正确安装。"
            read -p "按回车返回菜单..."
            continue
        fi

        echo ""
        echo "当前客户端证书列表："

        CLIENTS=""
        count=0
        while IFS= read -r file; do
            [ -n "$file" ] && {
                CLIENTS="$CLIENTS $file"
                count=$((count + 1))
            }
        done < <(ls -1 "$EASYRSA_DIR"/pki/issued/ 2>/dev/null | grep -v '^server\.crt$' | sed 's/\.crt$//')

        if [ $count -eq 0 ]; then
            echo "暂无客户端证书可删除。"
            read -p "按回车返回菜单..."
            continue
        fi

        set -- $CLIENTS
        i=1
        while [ $# -gt 0 ]; do
            echo "  $i) $1"
            shift
            i=$((i + 1))
        done
        echo ""

        read -p "要删除的客户端编号（1-$((i-1))，q取消）： " del_choice
        [ "$del_choice" = "q" ] || [ "$del_choice" = "Q" ] && continue

        if ! echo "$del_choice" | grep -qE '^[0-9]+$' || [ "$del_choice" -lt 1 ] || [ "$del_choice" -ge $i ]; then
            echo "无效选择"
            continue
        fi

        set -- $CLIENTS
        j=1
        while [ $j -lt "$del_choice" ]; do
            shift
            j=$((j + 1))
        done
        DEL_CLIENT="$1"
        echo "将删除客户端：$DEL_CLIENT"

        read -p "确认删除 $DEL_CLIENT？(y/n，回车 n)： " del_confirm
        del_confirm=${del_confirm:-n}

        if [ "$del_confirm" != "y" ] && [ "$del_confirm" != "Y" ]; then
            continue
        fi

        cd "$EASYRSA_DIR"

        echo "yes" | ./easyrsa revoke "$DEL_CLIENT" 2>/dev/null || echo "撤销失败（可能已撤销）"
        ./easyrsa gen-crl
        cp pki/crl.pem /etc/openvpn/ 2>/dev/null || true

        rm -f "pki/issued/${DEL_CLIENT}.crt" 2>/dev/null
        rm -f "pki/private/${DEL_CLIENT}.key" 2>/dev/null
        rm -f "$CCD_DIR/$DEL_CLIENT" 2>/dev/null
        rm -f "/etc/openvpn/client-${DEL_CLIENT}.ovpn" 2>/dev/null

        echo ""
        echo "已删除 $DEL_CLIENT 相关文件和证书记录。"
        echo "CRL 已更新。"
        echo "建议执行：$SERVICE_RESTART"
        echo ""
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式8：重启 OpenVPN 服务
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "8" ]; then
        echo "正在重启 OpenVPN 服务..."
        $SERVICE_RESTART
        echo "服务已重启。按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式9：停止 OpenVPN 服务
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "9" ]; then
        echo "正在停止 OpenVPN 服务..."
        $SERVICE_STOP
        echo "服务已停止。按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式10：开机启动 OpenVPN 服务
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "10" ]; then
        echo "正在设置 OpenVPN 服务为开机启动..."
        $SERVICE_ENABLE
        echo "服务已设置为开机启动。按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式11：关闭开机启动 OpenVPN 服务
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "11" ]; then
        echo "正在关闭 OpenVPN 服务的开机启动..."
        $SERVICE_DISABLE
        echo "服务已设置为不在开机时启动。按回车返回主菜单..."
        read -p ""
        continue
    fi

    echo "无效选项，按回车返回主菜单..."
    read -p ""
done
