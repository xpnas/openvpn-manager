#!/bin/sh
# OpenVPN TCP 客户端管理脚本 - 兼容 Alpine & Debian/Ubuntu (最终极简版)
# 功能：安装客户端 / 导入 .ovpn（自动补全日志记录） / 连接（5秒动态检查） / 断开 / 开机自启 / 卸载 / 查看日志
# 优化：
#   - 模式3：静默启动服务 + 强制5次检查
#   - 成功/失败只显示简短提示，不显示任何日志内容
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
    echo "不支持的系统！仅支持 Alpine 或 Debian/Ubuntu"
    exit 1
fi

echo "检测到系统：$OS"
echo "配置文件：$CONFIG_FILE"
echo "日志文件：$LOG_FILE"
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
    echo "5) 设置开机自启"
    echo "6) 取消开机自启"
    echo "7) 查看连接状态 / 日志"
    echo "8) 卸载 OpenVPN 客户端"
    echo "0) 退出脚本"
    echo ""
    echo "请选择操作（0~8，回车默认1）： "
    read mode_choice
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
        $PKG_UPDATE
        $PKG_INSTALL openvpn
        echo "安装完成。"
        echo ""
        echo "按回车返回主菜单..."
        read dummy
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式2：导入 .ovpn 配置文件（自动补全日志）
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "2" ]; then
        echo "请输入 .ovpn 文件完整路径： "
        read ovpn_path

        if [ -z "$ovpn_path" ] || [ ! -f "$ovpn_path" ]; then
            echo "错误：文件不存在或路径无效"
            echo "按回车返回菜单..."
            read dummy
            continue
        fi

        if [ "$OS" = "alpine" ]; then
            TARGET_FILE="/etc/openvpn/openvpn.conf"
        else
            TARGET_FILE="/etc/openvpn/client.conf"
        fi

        cp "$ovpn_path" "$TARGET_FILE"
        chmod 600 "$TARGET_FILE"
        chown root:root "$TARGET_FILE" 2>/dev/null || true

        ADDED=0
        if ! grep -qi "verb" "$TARGET_FILE"; then
            echo "verb 3" >> "$TARGET_FILE"
            ADDED=1
        fi
        if ! grep -qi "log-append" "$TARGET_FILE"; then
            echo "log-append $LOG_FILE" >> "$TARGET_FILE"
            ADDED=1
        fi

        if [ $ADDED -eq 1 ]; then
            echo "已补全日志记录：$LOG_FILE"
        else
            echo "已包含 verb 和 log-append，无需修改"
        fi

        echo "导入完成：$TARGET_FILE"
        echo ""
        echo "按回车返回主菜单..."
        read dummy
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式3：连接 VPN（静默启动 + 强制5次检查）
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "3" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "错误：未找到配置文件 $CONFIG_FILE"
            echo "请先使用模式 2 导入"
            echo "按回车继续..."
            read dummy
            continue
        fi

        echo "正在连接 VPN..."

        # 静默启动服务，避免任何输出打断
        $SERVICE_START >/dev/null 2>&1 &

        echo "服务启动中，正在检查连接状态（每1秒检查一次，共5次）..."

        SUCCESS=0
        for i in {1..5}; do
            sleep 1
            if [ -f "$LOG_FILE" ]; then
                if tail -n 200 "$LOG_FILE" | grep -q "Initialization Sequence Completed"; then
                    SUCCESS=1
                    echo ""
                    echo "连接成功！"
                    break
                fi
            fi
        done

        if [ $SUCCESS -eq 0 ]; then
            echo ""
            echo "连接未成功（5秒内未检测到完成标志）"
            echo "请稍后使用模式 7 查看详细日志，或检查服务器状态"
        fi

        echo ""
        echo "按回车返回主菜单..."
        read dummy
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式4：断开 VPN
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "4" ]; then
        echo "正在断开 VPN..."
        $SERVICE_STOP 2>/dev/null || echo "服务已停止或未运行"
        echo "断开完成"
        echo "按回车返回主菜单..."
        read dummy
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式5：设置开机自启
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "5" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "错误：未找到配置文件"
            echo "按回车继续..."
            read dummy
            continue
        fi
        $SERVICE_ENABLE 2>/dev/null || true
        echo "已设置开机自启"
        echo "按回车返回主菜单..."
        read dummy
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式6：取消开机自启
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "6" ]; then
        $SERVICE_DISABLE 2>/dev/null || true
        echo "已取消开机自启"
        echo "按回车返回主菜单..."
        read dummy
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式7：查看连接状态 / 日志
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "7" ]; then
        echo "当前连接状态："
        if [ "$OS" = "alpine" ]; then
            rc-service openvpn status 2>/dev/null || echo "服务未运行"
        else
            systemctl status openvpn@client --no-pager -l 2>/dev/null || echo "服务未运行"
        fi

        echo ""
        echo "最近日志（已去除时间戳）："
        echo "------------------------------------------------------------"
        if [ -f "$LOG_FILE" ]; then
            tail -n 40 "$LOG_FILE" | sed 's/^[^ ]* [^ ]* [^ ]* [^ ]* //'
        else
            echo "日志文件尚未生成"
        fi

        echo ""
        echo "按回车返回主菜单..."
        read dummy
        continue
    fi

    # ─────────────────────────────────────────────────────────────
    # 模式8：卸载 OpenVPN 客户端
    # ─────────────────────────────────────────────────────────────
    if [ "$MODE" = "8" ]; then
        echo "警告：将删除所有配置和日志！"
        echo "输入 YES 确认： "
        read confirm
        if [ "$confirm" != "YES" ]; then
            continue
        fi

        $SERVICE_STOP 2>/dev/null || true
        $SERVICE_DISABLE 2>/dev/null || true

        rm -rf "$CONFIG_DIR"/* 2>/dev/null
        rm -f "$LOG_FILE" 2>/dev/null

        $PKG_REMOVE openvpn 2>/dev/null || true

        echo "卸载完成。"
        echo "按回车返回主菜单..."
        read dummy
        continue
    fi

    echo "无效选项"
    echo "按回车返回主菜单..."
    read dummy
done
