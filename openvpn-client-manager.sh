#!/bin/sh
# OpenVPN TCP 客户端管理脚本 - 兼容 Alpine & Debian/Ubuntu (完整版)
# 功能：安装客户端 / 导入 .ovpn / 连接/断开 / 开机自启 / 卸载
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
    CONFIG_DIR="/etc/openvpn"
    CONFIG_FILE="$CONFIG_DIR/client.conf"
    USE_SYSTEMD=0
elif [ -f /etc/debian_version ] || grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
    OS="debian"
    PKG_INSTALL="apt update && apt install -y"
    PKG_REMOVE="apt purge -y"
    PKG_UPDATE="apt update"
    SERVICE_START="systemctl start openvpn@client"
    SERVICE_STOP="systemctl stop openvpn@client"
    SERVICE_RESTART="systemctl restart openvpn@client"
    SERVICE_ENABLE="systemctl enable openvpn@client"
    SERVICE_DISABLE="systemctl disable openvpn@client"
    CONFIG_DIR="/etc/openvpn"
    CONFIG_FILE="$CONFIG_DIR/client.conf"
    USE_SYSTEMD=1
else
    echo "不支持的系统！仅支持 Alpine Linux 或 Debian/Ubuntu"
    exit 1
fi

echo "检测到系统：$OS"
echo "客户端配置文件路径：$CONFIG_FILE"
echo ""

# ─────────────────────────────────────────────────────────────
# 主菜单循环
# ─────────────────────────────────────────────────────────────
while true; do
    clear

    echo "=== OpenVPN TCP 客户端管理脚本 ==="
    echo "1) 安装 OpenVPN 客户端"
    echo "2) 导入 .ovpn 配置文件"
    echo "3) 连接 VPN"
    echo "4) 断开 VPN"
    echo "5) 设置开机自启 VPN 连接"
    echo "6) 取消开机自启"
    echo "7) 查看连接状态"
    echo "8) 卸载 OpenVPN 客户端和所有配置"
    echo "0) 退出脚本"
    echo ""
    read -p "请选择操作（0~8，回车默认1）： " mode_choice
    MODE=${mode_choice:-1}

    if [ "$MODE" = "0" ]; then
        echo "已退出脚本。"
        exit 0
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式1：安装 OpenVPN 客户端
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "1" ]; then
        echo "正在安装 OpenVPN 客户端..."

        if [ "$OS" = "alpine" ]; then
            $PKG_UPDATE
            $PKG_INSTALL openvpn
        else
            $PKG_UPDATE
            $PKG_INSTALL openvpn
        fi

        echo ""
        echo "OpenVPN 客户端安装完成。"
        echo "下一步：请使用模式 2 导入 .ovpn 文件"
        echo ""
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式2：导入 .ovpn 配置文件
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "2" ]; then
        read -p "请输入 .ovpn 文件的完整路径（例如 /root/myvpn.ovpn）： " ovpn_path

        if [ -z "$ovpn_path" ] || [ ! -f "$ovpn_path" ]; then
            echo "错误：文件不存在或路径无效"
            echo "按回车返回菜单..."
            read -p ""
            continue
        fi

        # 复制到标准位置
        cp "$ovpn_path" "$CONFIG_FILE"

        # 确保权限正确
        chmod 600 "$CONFIG_FILE"

        echo ""
        echo "成功导入！配置文件已保存到：$CONFIG_FILE"
        echo "你现在可以使用模式 3 连接 VPN"
        echo ""
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式3：连接 VPN
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "3" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "错误：未找到客户端配置文件 $CONFIG_FILE"
            echo "请先使用模式 2 导入 .ovpn 文件"
            read -p "按回车继续..."
            continue
        fi

        echo "正在连接 VPN..."
        $SERVICE_START || {
            echo "连接失败，请检查配置文件或日志："
            if [ "$OS" = "alpine" ]; then
                tail -n 20 /var/log/openvpn.log 2>/dev/null || echo "日志文件不存在"
            else
                journalctl -u openvpn@client -n 20
            fi
        }

        echo ""
        echo "连接命令已执行（是否成功请查看日志）"
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式4：断开 VPN
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "4" ]; then
        echo "正在断开 VPN..."
        $SERVICE_STOP 2>/dev/null || echo "服务已停止或未运行"

        echo ""
        echo "断开命令已执行"
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式5：设置开机自启
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "5" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "错误：未找到客户端配置文件，请先导入 .ovpn"
            read -p "按回车继续..."
            continue
        fi

        $SERVICE_ENABLE 2>/dev/null || true

        if [ "$OS" = "alpine" ]; then
            echo "已启用开机自启（openrc）"
        else
            echo "已启用开机自启（systemd）"
        fi

        echo ""
        echo "重启系统后将自动连接 VPN"
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式6：取消开机自启
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "6" ]; then
        $SERVICE_DISABLE 2>/dev/null || true

        if [ "$OS" = "alpine" ]; then
            echo "已取消开机自启（openrc）"
        else
            echo "已取消开机自启（systemd）"
        fi

        echo ""
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式7：查看连接状态
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "7" ]; then
        echo "当前 VPN 连接状态："
        echo ""

        if [ "$OS" = "alpine" ]; then
            rc-service openvpn status 2>/dev/null || echo "服务未运行"
            echo ""
            echo "最近日志："
            tail -n 20 /var/log/openvpn.log 2>/dev/null || echo "日志文件不存在"
        else
            systemctl status openvpn@client --no-pager -l || echo "服务未运行"
            echo ""
            echo "最近日志："
            journalctl -u openvpn@client -n 20 --no-pager
        fi

        echo ""
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式8：卸载 OpenVPN 客户端
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "8" ]; then
        echo "警告：这将卸载 OpenVPN 客户端并删除所有配置！"
        read -p "输入 YES 确认卸载： " confirm
        if [ "$confirm" != "YES" ]; then
            continue
        fi

        echo "正在卸载..."

        $SERVICE_STOP 2>/dev/null || true
        $SERVICE_DISABLE 2>/dev/null || true

        rm -rf "$CONFIG_DIR"/* 2>/dev/null

        $PKG_REMOVE openvpn 2>/dev/null || true

        echo ""
        echo "卸载完成。"
        echo "所有 OpenVPN 客户端文件和配置已删除。"
        echo "按回车返回主菜单..."
        read -p ""
        continue
    fi

    echo "无效选项，按回车返回主菜单..."
    read -p ""
done
