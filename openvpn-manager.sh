#!/bin/sh
# Alpine OpenVPN TCP 管理脚本（最终完整版 2026）
# 功能：apk源切换 → 安装服务端 → 添加客户端 → 端口放行 → 特定客户端配置 → 全局自定义 → 卸载 → 删除客户端
# 配置文件统一使用 /etc/openvpn/openvpn.conf（Alpine默认路径）
# 默认绕过列表只定义一次，所有模式共用
# 主菜单循环（0退出），添加客户端后可直接配置
# POSIX兼容（无mapfile），兼容ash shell

set -e

# 默认的中国 IP 绕过列表（38条 /8 段，只定义一次）
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

echo "=== Alpine OpenVPN TCP 管理脚本（最终完整版）==="
echo "当前时间：$(date '+%Y-%m-%d %H:%M')"
echo ""

# ─────────────────────────────────────────────────────────────
# apk 源切换（仅第一次运行时询问）
# ─────────────────────────────────────────────────────────────
if [ ! -f /etc/apk/repositories.bak ]; then
    echo "检测到首次运行，推荐更换 apk 源（清华源有时同步问题）。"
    echo "推荐使用阿里云镜像（国内高速、稳定）。"
    echo ""
    echo "选项："
    echo "  1) 阿里云 (mirrors.aliyun.com) ← 推荐"
    echo "  2) 清华 TUNA"
    echo "  3) 中科大"
    echo "  4) 官方 CDN"
    echo "  5) 跳过"
    read -p "选择（1~5，回车1）： " mirror_choice
    mirror_choice=${mirror_choice:-1}

    if [ "$mirror_choice" != "5" ]; then
        cp /etc/apk/repositories /etc/apk/repositories.bak 2>/dev/null || true

        ALPINE_VER=$(cat /etc/alpine-release | cut -d. -f1-2 2>/dev/null || echo "edge")
        [ "$ALPINE_VER" = "edge" ] && {
            MAIN_REPO="edge/main"
            COMM_REPO="edge/community"
        } || {
            MAIN_REPO="v${ALPINE_VER}/main"
            COMM_REPO="v${ALPINE_VER}/community"
        }

        case $mirror_choice in
            1) MIRROR="https://mirrors.aliyun.com/alpine" ;;
            2) MIRROR="https://mirrors.tuna.tsinghua.edu.cn/alpine" ;;
            3) MIRROR="https://mirrors.ustc.edu.cn/alpine" ;;
            4) MIRROR="https://dl-cdn.alpinelinux.org/alpine" ;;
            *) MIRROR="https://mirrors.aliyun.com/alpine" ;;
        esac

        cat > /etc/apk/repositories << EOF
${MIRROR}/${MAIN_REPO}
${MIRROR}/${COMM_REPO}
EOF

        echo "源已切换为 ${MIRROR}"
        apk update || {
            echo "apk update 失败！已恢复备份。"
            cp /etc/apk/repositories.bak /etc/apk/repositories 2>/dev/null
        }
    fi
fi

# ─────────────────────────────────────────────────────────────
# 变量定义
# ─────────────────────────────────────────────────────────────
EASYRSA_DIR="/etc/openvpn/easy-rsa"
SERVER_CONF="/etc/openvpn/openvpn.conf"
CCD_DIR="/etc/openvpn/ccd"
CLIENT_DIR="/etc/openvpn"

# ─────────────────────────────────────────────────────────────
# 主菜单循环
# ─────────────────────────────────────────────────────────────
while true; do
    clear

    if [ -f "$SERVER_CONF" ]; then
        echo "服务端已安装。"
        echo "1) 添加新客户端"
        echo "2) 放行/检查 VPN 端口（TCP）"
        echo "3) 配置特定客户端（LAN + 固定IP + push）"
        echo "4) 全局自定义配置（中国IP绕过、DNS、LAN 等）"
        echo "5) 重新安装/覆盖服务端配置"
        echo "6) 卸载 OpenVPN 和所有配置"
        echo "7) 删除指定客户端（证书 + ccd + .ovpn）"
        echo "0) 退出脚本"
        echo ""
        read -p "请选择操作（0~7，回车默认1）： " mode_choice
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
    # 模式1：添加新客户端 + 询问是否立即配置该客户端
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "1" ]; then
        if [ ! -d "$EASYRSA_DIR" ] || [ ! -f "$SERVER_CONF" ]; then
            echo "错误：服务端未正确安装。请先选择模式 5。"
            echo "按回车继续..."
            read -p ""
            continue
        fi

        cd "$EASYRSA_DIR"

        PORT=$(grep '^port ' "$SERVER_CONF" | awk '{print $2}' || echo "51820")
        SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || curl -s https://icanhazip.com 2>/dev/null || echo "YOUR_SERVER_IP")

        echo "读取配置：端口 $PORT，服务器 IP $SERVER_IP"
        read -p "修改 IP？（回车保持）： " input_ip
        SERVER_IP=${input_ip:-$SERVER_IP}

        read -p "客户端名称： " CLIENT_NAME
        [ -z "$CLIENT_NAME" ] && { echo "必须输入名称"; continue; }

        echo "1) 有密码   2) 无密码（nopass）"
        read -p "选择（回车2）： " pass_choice
        EXTRA=$([ "${pass_choice:-2}" = "1" ] && echo "" || echo "nopass")

        ./easyrsa build-client-full "$CLIENT_NAME" $EXTRA

        CIPHER=$(grep '^cipher ' "$SERVER_CONF" | awk '{print $2}' || echo "AES-256-GCM")
        AUTH=$(grep '^auth ' "$SERVER_CONF" | awk '{print $2}' || echo "SHA512")

        cat > "${CLIENT_DIR}/client-${CLIENT_NAME}.ovpn" << EOF
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
        echo "客户端配置文件生成： ${CLIENT_DIR}/client-${CLIENT_NAME}.ovpn"

        read -p "是否立即为 $CLIENT_NAME 配置（LAN、固定IP、push 等）？(y/n，回车 y)： " configure_now
        configure_now=${configure_now:-y}

        if [ "$configure_now" = "y" ] || [ "$configure_now" = "Y" ]; then
            AUTO_CLIENT_NAME="$CLIENT_NAME"
            MODE=3
        fi
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式3：特定客户端配置
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "3" ]; then
        if [ ! -d "$EASYRSA_DIR" ] || [ ! -f "$SERVER_CONF" ]; then
            echo "错误：服务端未正确安装。"
            echo "按回车返回菜单..."
            read -p ""
            continue
        fi

        mkdir -p "$CCD_DIR"
        grep -q '^client-config-dir' "$SERVER_CONF" || echo "client-config-dir $CCD_DIR" >> "$SERVER_CONF"
        grep -q '^client-to-client' "$SERVER_CONF" || {
            read -p "是否启用 client-to-client？(y/n，回车 y)： " c2c
            [ "${c2c:-y}" = "y" ] && echo "client-to-client" >> "$SERVER_CONF"
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
            echo "按回车返回菜单..."
            read -p ""
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
            grep -q "route $CLIENT_LAN_NET" "$SERVER_CONF" || {
                echo "route $CLIENT_LAN_NET $CLIENT_LAN_MASK" >> "$SERVER_CONF"
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
        echo "执行：rc-service openvpn restart"
        echo ""
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式2：端口放行
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "2" ]; then
        if [ ! -f "$SERVER_CONF" ]; then
            echo "错误：服务端未安装。"
            echo "按回车返回菜单..."
            read -p ""
            continue
        fi

        PORT=$(grep '^port ' "$SERVER_CONF" | awk '{print $2}' || echo "51820")
        echo "当前监听端口：TCP $PORT"

        read -p "是否自动放行端口（iptables + 开机持久）？输入 YES 确认： " confirm
        if [ "$confirm" = "YES" ]; then
            iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
            mkdir -p /etc/local.d
            cat > /etc/local.d/openvpn-firewall.start << EOF
#!/bin/sh
iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
EOF
            chmod +x /etc/local.d/openvpn-firewall.start
            echo "已放行并创建开机规则。"
        fi

        echo "当前 INPUT 链中相关规则："
        iptables -L INPUT -v -n | grep "$PORT" || echo "未找到相关规则"
        echo "提醒：云厂商安全组仍需手动放行 TCP $PORT"
        echo ""
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式4：全局自定义配置
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "4" ]; then
        if [ ! -f "$SERVER_CONF" ]; then
            echo "错误：服务端未安装。"
            echo "按回车返回菜单..."
            read -p ""
            continue
        fi

        echo "=== 全局配置修改（影响所有客户端）==="
        echo ""

        read -p "是否修改中国IP绕过列表？(y/n)： " add_bypass
        if [ "$add_bypass" = "y" ] || [ "$add_bypass" = "Y" ]; then
            echo ""
            echo "1) 使用默认列表（38条常见中国大陆段）"
            echo "2) 手动输入新列表（清空旧的）"
            echo "3) 追加到现有"
            echo "4) 跳过"
            read -p "选择（1~4，回车1）： " ch
            ch=${ch:-1}

            case $ch in
                1)
                    sed -i '/^push "route .* net_gateway"/d' "$SERVER_CONF"
                    echo "$DEFAULT_BYPASS_PUSH" >> "$SERVER_CONF"
                    echo "已导入默认 38 条绕过段"
                    ;;
                2)
                    sed -i '/^push "route .* net_gateway"/d' "$SERVER_CONF"
                    echo "请输入新段（格式 1.0.0.0 255.0.0.0，每行一个，空行结束）："
                    while read -p "> " line; do
                        [ -z "$line" ] && break
                        echo "push \"route $line net_gateway\"" >> "$SERVER_CONF"
                    done
                    ;;
                3)
                    echo "请输入追加段（同上格式）："
                    while read -p "> " line; do
                        [ -z "$line" ] && break
                        echo "push \"route $line net_gateway\"" >> "$SERVER_CONF"
                    done
                    ;;
                *) echo "跳过绕过修改" ;;
            esac
        fi

        read -p "是否更新全局 DNS push？(y/n)： " dns_yn
        if [ "$dns_yn" = "y" ] || [ "$dns_yn" = "Y" ]; then
            read -p "输入 DNS（空格分隔，例如 192.168.5.4 223.5.5.5）： " dns_list
            [ -n "$dns_list" ] && {
                sed -i '/^push "dhcp-option DNS /d' "$SERVER_CONF"
                for dns in $dns_list; do echo "push \"dhcp-option DNS $dns\"" >> "$SERVER_CONF"; done
            }
        fi

        read -p "是否添加/更新全局 LAN route/push（例如 192.168.5.0/24，回车跳过）： " lan
        if [ -n "$lan" ]; then
            net=$(echo "$lan" | cut -d/ -f1)
            mask="255.255.255.0"
            sed -i "/^route $net /d" "$SERVER_CONF"
            sed -i "/^push \"route $net /d" "$SERVER_CONF"
            echo "route $net $mask" >> "$SERVER_CONF"
            echo "push \"route $net $mask\"" >> "$SERVER_CONF"
        fi

        echo ""
        echo "全局配置更新完成。执行：rc-service openvpn restart"
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

        PORT=51820
        read -p "监听端口（默认 51820）： " p
        PORT=${p:-51820}

        VPN_NET="10.10.0.0"
        read -p "VPN 网段（默认 10.10.0.0）： " n
        VPN_NET=${n:-10.10.0.0}

        echo ""
        echo "加密选项："
        echo "1) AES-256-GCM + SHA384"
        echo "2) AES-256-GCM + SHA512（你的常用）"
        echo "3) AES-128-GCM + SHA256"
        echo "4) CHACHA20-POLY1305 + SHA256"
        echo "5) 无加密（仅测试！）"
        read -p "选择（1~5，回车2）： " enc
        enc=${enc:-2}

        case "$enc" in
            1)
                CIPHER="AES-256-GCM"
                AUTH="SHA384"
                TLS_MIN="1.2"
                ;;
            2)
                CIPHER="AES-256-GCM"
                AUTH="SHA512"
                TLS_MIN="1.2"
                ;;
            3)
                CIPHER="AES-128-GCM"
                AUTH="SHA256"
                TLS_MIN="1.2"
                ;;
            4)
                CIPHER="CHACHA20-POLY1305"
                AUTH="SHA256"
                TLS_MIN="1.2"
                ;;
            5)
                echo "警告：无加密模式！数据明文传输。"
                read -p "真的要继续？输入 YES（大写）确认，否则按回车退出： " confirm
                if [ "$confirm" != "YES" ]; then
                    echo "已取消安装。"
                    continue
                fi
                CIPHER="none"
                AUTH="none"
                TLS_MIN="1.2"
                ;;
            *)
                echo "无效选择，使用默认（AES-256-GCM + SHA512）"
                CIPHER="AES-256-GCM"
                AUTH="SHA512"
                TLS_MIN="1.2"
                ;;
        esac

        echo "配置预览：端口 $PORT，网段 $VPN_NET/24，$CIPHER + $AUTH"
        sleep 3

        apk add --no-cache openvpn easy-rsa iptables openssl ca-certificates curl

        mkdir -p "$EASYRSA_DIR"
        cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR/" 2>/dev/null || true
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

        SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://icanhazip.com || ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        [ -z "$SERVER_IP" ] && read -p "无法获取公网IP，请手动输入：" SERVER_IP

        cat > "$SERVER_CONF" << EOF
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
group nobody
persist-key
persist-tun
verb 3
EOF

        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        sysctl -p

        OUT_IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
        iptables -t nat -A POSTROUTING -s ${VPN_NET}/24 -o "$OUT_IFACE" -j MASQUERADE

        mkdir -p /etc/local.d
        cat > /etc/local.d/openvpn-nat.start << EOF
#!/bin/sh
iptables -t nat -A POSTROUTING -s ${VPN_NET}/24 -o $OUT_IFACE -j MASQUERADE
EOF
        chmod +x /etc/local.d/openvpn-nat.start

        rc-update add openvpn default
        rc-service openvpn restart || rc-service openvpn start

        echo ""
        echo "服务端安装完成。"
        echo "端口：$PORT    IP：$SERVER_IP"
        echo "配置文件路径：$SERVER_CONF"
        echo "请使用模式 1 添加客户端，模式 3/4 配置路由/DNS"
        echo "云安全组记得放行 TCP $PORT"
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式6：卸载 OpenVPN 和所有配置
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "6" ]; then
        echo "=== 卸载 OpenVPN 和所有配置 ==="
        echo "警告：这将删除所有证书、配置文件、NAT规则、开机自启等！"
        echo "此操作不可逆，请确认是否继续。"
        read -p "输入 YES（大写）确认卸载，否则按回车退出： " confirm
        if [ "$confirm" != "YES" ]; then
            echo "已取消卸载。"
            continue
        fi

        echo "正在卸载..."

        rc-service openvpn stop 2>/dev/null || true
        rc-update del openvpn default 2>/dev/null || true

        iptables -t nat -D POSTROUTING -s 10.10.0.0/24 -j MASQUERADE 2>/dev/null || true
        PORT=$(grep '^port ' "$SERVER_CONF" 2>/dev/null | awk '{print $2}' || echo "51820")
        iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true

        rm -f /etc/local.d/openvpn-nat.start /etc/local.d/openvpn-firewall.start 2>/dev/null

        rm -rf /etc/openvpn/* 2>/dev/null
        rm -rf "$EASYRSA_DIR" 2>/dev/null

        apk del --purge openvpn easy-rsa iptables openssl ca-certificates curl 2>/dev/null || true

        sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf 2>/dev/null
        sysctl -p 2>/dev/null || true

        echo ""
        echo "卸载完成！"
        echo "已删除所有 OpenVPN 相关文件、证书、规则和包。"
        echo "如需重新安装，请再次运行脚本并选择模式 5。"
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式7：删除指定客户端
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "7" ]; then
        if [ ! -d "$EASYRSA_DIR" ] || [ ! -f "$SERVER_CONF" ]; then
            echo "错误：服务端未正确安装。"
            echo "按回车返回菜单..."
            read -p ""
            continue
        fi

        echo ""
        echo "当前客户端证书列表（可删除）："

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
            echo "按回车返回菜单..."
            read -p ""
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

        read -p "请输入要删除的客户端编号（1-$((i-1))，q取消）： " del_choice
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

        read -p "确认删除 $DEL_CLIENT 及其所有相关文件？(y/n，回车 n)： " del_confirm
        del_confirm=${del_confirm:-n}

        if [ "$del_confirm" != "y" ] && [ "$del_confirm" != "Y" ]; then
            echo "取消删除。"
            continue
        fi

        cd "$EASYRSA_DIR"

        # 撤销证书并更新 CRL
        echo "yes" | ./easyrsa revoke "$DEL_CLIENT" 2>/dev/null || echo "撤销证书失败（可能已撤销）"
        ./easyrsa gen-crl
        cp pki/crl.pem /etc/openvpn/ 2>/dev/null || true

        # 删除文件
        rm -f "pki/issued/${DEL_CLIENT}.crt" 2>/dev/null
        rm -f "pki/private/${DEL_CLIENT}.key" 2>/dev/null
        rm -f "$CCD_DIR/$DEL_CLIENT" 2>/dev/null
        rm -f "$CLIENT_DIR/client-${DEL_CLIENT}.ovpn" 2>/dev/null

        echo ""
        echo "已删除客户端 $DEL_CLIENT 的所有文件和证书记录。"
        echo "CRL 已更新，客户端将无法继续连接。"
        echo "建议执行：rc-service openvpn restart"
        echo ""
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    echo "无效选项，按回车返回主菜单..."
    read -p ""
done
