# OpenVPN 一键管理脚本

## 项目简介

适用于 **Alpine Linux** 和 **Debian/Ubuntu** 的 OpenVPN 全生命周期管理脚本，分为**服务端**和**客户端**两个脚本，均提供交互式主菜单，支持循环操作无需反复执行。

**特点：**
- 自动检测系统类型（Alpine / Debian）及防火墙类型（iptables / nftables）
- 添加客户端后可立即配置该客户端的路由/DNS/LAN 规则
- 删除客户端时自动 revoke 证书并更新 CRL
- POSIX 兼容，适配 Alpine 默认 ash shell

---

## 使用方法

### 服务端

```bash
wget -O openvpn-server-manager.sh https://raw.githubusercontent.com/xpnas/openvpn-manager/master/openvpn-server-manager.sh
chmod +x openvpn-server-manager.sh
./openvpn-server-manager.sh
```

### 客户端

```bash
wget -O openvpn-client-manager.sh https://raw.githubusercontent.com/xpnas/openvpn-manager/master/openvpn-client-manager.sh
chmod +x openvpn-client-manager.sh
./openvpn-client-manager.sh
```

---

## 服务端菜单（openvpn-server-manager.sh）

| 选项 | 功能 |
|------|------|
| **1** | 添加新客户端（生成 .ovpn 文件） |
| **2** | 放行/检查 VPN 端口（iptables/nftables + 开机持久） |
| **3** | 配置特定客户端（固定IP、LAN访问、全局代理、中国IP绕过、DNS） |
| **4** | 全局自定义配置（影响所有客户端的绕过/DNS/LAN） |
| **5** | 重新安装/覆盖服务端配置（重新生成证书） |
| **6** | 卸载 OpenVPN（删除所有文件、证书、规则、包） |
| **7** | 删除指定客户端（撤销证书、更新 CRL、删除文件） |
| **8** | 重启 OpenVPN 服务 |
| **9** | 停止 OpenVPN 服务 |
| **10** | 开机启动 OpenVPN 服务 |
| **11** | 关闭开机启动 OpenVPN 服务 |
| **12** | 查看所有客户端列表 |
| **13** | 查看服务运行状态 / 在线客户端 |
| **14** | 备份配置 |
| **15** | 恢复配置 |
| **16** | 重新导出客户端 .ovpn |
| **17** | 配置日志轮转 |
| **18** | 查看吊销证书列表 |
| **19** | 查看客户端流量统计 |
| **20** | 查看审计日志 |
| **22** | 设置出口网关客户端（将某客户端作为全局出口） |
| **0** | 退出脚本 |

---

## 客户端菜单（openvpn-client-manager.sh）

| 选项 | 功能 |
|------|------|
| **1** | 安装 OpenVPN 客户端 |
| **2** | 导入 .ovpn 配置文件 |
| **3** | 连接 VPN |
| **4** | 断开 VPN |
| **5** | 设置开机自启 |
| **6** | 取消开机自启 |
| **7** | 查看连接状态 / 日志 |
| **8** | 卸载 OpenVPN 客户端 |
| **9** | 管理配置文件（多配置） |
| **10** | 切换配置文件并连接 |
| **11** | DNS 泄漏检测 |
| **12** | 自动重连守护 |
| **13** | 查看审计日志 |
| **0** | 退出脚本 |

---

## 出口网关架构（模式 22）

将某个 VPN 客户端 C 作为其他客户端的出口网关，适用于"通过内网机器代理出境流量"的场景。

```
其他VPN客户端(B) ──┐
VPN服务端(S)    ──┤── [tun0] ── C(网关客户端) ── G(局域网网关) ── 公网
                  │             172.27.0.5       192.168.5.4
                  │             192.168.5.5
```

**配置要点：**
- 模式 22 在选定客户端的 CCD 文件中写入 `iroute 0.0.0.0 0.0.0.0`，并配置服务端策略路由
- C（网关客户端机器）：只开启 `ip_forward`，**不做 MASQUERADE**，保持源 IP = VPN IP
- G（局域网网关）：配置 MASQUERADE + 到 VPN 网段的回程路由

---

