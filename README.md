# Alpine OpenVPN TCP 一键管理脚本

## 项目简介

这是一个专为 **Alpine Linux** 设计的 **OpenVPN TCP 服务端管理脚本**，提供完整的交互式菜单，支持从安装到卸载的全生命周期管理。

脚本特点：
- 主菜单循环（支持返回上一层，无需反复执行脚本）
- 自动检测并引导安装
- 支持国内高速 apk 源切换（默认阿里云）
- 添加客户端后可立即配置该客户端
- 支持全局 + 针对单个客户端的自定义路由/DNS/绕过规则
- 删除客户端时自动 revoke 证书并更新 CRL
- POSIX 兼容，运行在 Alpine 默认 ash shell 下（无需 bash）
- 配置文件统一使用 `/etc/openvpn/openvpn.conf`（Alpine 官方默认路径）

## 支持的操作（主菜单）

| 选项 | 功能描述 |
|------|----------|
| 1    | 添加新客户端（生成 .ovpn 文件） |
| 2    | 放行/检查 VPN 端口（iptables + 开机持久） |
| 3    | 配置特定客户端（固定IP、LAN访问、全局代理、中国IP绕过、DNS） |
| 4    | 全局自定义配置（影响所有客户端的绕过/DNS/LAN） |
| 5    | 重新安装/覆盖服务端配置（重新生成证书等） |
| 6    | 卸载 OpenVPN（删除所有文件、证书、规则、包） |
| 7    | 删除指定客户端（撤销证书、更新 CRL、删除文件） |
| 0    | 退出脚本 |

## 使用方法

1. 下载脚本
   ```bash
   wget https://github.com/xpnas/openvpn-manager/blob/master/openvpn-manager.sh -O openvpn-manager.sh
   # 或手动上传 / 复制粘贴
