# 介绍

最好用的 sing-box 一键安装脚本 & 管理脚本

# 特点

- 快速安装
- 无敌好用
- 零学习成本
- 自动化 TLS
- 简化所有流程
- 兼容 sing-box 命令
- 强大的快捷参数
- 支持所有常用协议
- 一键添加 VLESS-REALITY
- 一键添加 TUIC
- 一键添加 Trojan
- 一键添加 Hysteria2
- 一键添加 AnyTLS
- 一键添加 Shadowsocks 2022
- 一键添加 VMess-(TCP/HTTP/QUIC)
- 一键添加 VMess-(WS/H2/HTTPUpgrade)-TLS
- 一键添加 VLESS-(WS/H2/HTTPUpgrade)-TLS
- 一键添加 Trojan-(WS/H2/HTTPUpgrade)-TLS
- 一键启用 BBR
- 一键更改伪装网站
- 一键更改 (端口/UUID/密码/域名/路径/加密方式/SNI/等...)
- 还有更多...

# 设计理念

设计理念为：**高效率，超快速，极易用**

脚本基于作者的自身使用需求，以 **多配置同时运行** 为核心设计

并且专门优化了，添加、更改、查看、删除、这四项常用功能

你只需要一条命令即可完成 添加、更改、查看、删除、等操作

例如，添加一个配置仅需不到 1 秒！瞬间完成添加！其他操作亦是如此！

脚本的参数非常高效率并且超级易用，请掌握参数的使用

# 文档

使用：`sing-box help`

安装完成后不会自动创建任何代理协议配置，请进入菜单手动选择需要添加的协议。
After installation, no proxy protocol is created automatically. Use the menu to add the protocol you need.

## Backup / Rollback / Version policy

Before changing key files, the script creates a local backup transaction under `/etc/sing-box/backups/`.
Each transaction writes a `manifest.json` and updates `/etc/sing-box/backups/latest` after the manifest is complete.

Use `sb rollback` to restore the latest script-managed change. Use `sb rollback --dry-run` to print the rollback plan without changing files, and `sb rollback --yes` to skip the confirmation prompt.

The script uses a pinned stable sing-box version by default: `v1.13.8`.
Use `--latest` only if you explicitly want the latest upstream release, because latest may introduce breaking changes.
User-specified versions such as `bash install.sh -v v1.13.8` or `sb update core --core-version v1.13.8` take priority over the default pin.

Rollback only covers key files managed by this script, including sing-box config files, Caddy config files, service files, and managed binaries.
Rollback does not roll back system package installation, firewall changes made outside the managed files, `/root/.bashrc` alias edits, or Caddy certificate cache.

# 帮助

使用：`sing-box help`

```
sing-box script v1.17
Usage: sing-box [options]... [args]...

基本:
   v, version                                      显示当前版本
   ip                                              返回当前主机的 IP
   pbk                                             同等于 sing-box generate reality-keypair
   get-port                                        返回一个可用的端口
   ss2022                                          返回一个可用于 Shadowsocks 2022 的密码

一般:
   a, add [protocol] [args... | auto]              添加配置
   c, change [name] [option] [args... | auto]      更改配置
   d, del [name]                                   删除配置**
   i, info [name]                                  查看配置
   qr [name]                                       二维码信息
   url [name]                                      URL 信息
   log                                             查看日志
更改:
   full [name] [...]                               更改多个参数
   id [name] [uuid | auto]                         更改 UUID
   host [name] [domain]                            更改域名
   port [name] [port | auto]                       更改端口
   path [name] [path | auto]                       更改路径
   passwd [name] [password | auto]                 更改密码
   key [name] [Private key | atuo] [Public key]    更改密钥
   method [name] [method | auto]                   更改加密方式
   sni [name] [ ip | domain]                       更改 serverName
   new [name] [...]                                更改协议
   web [name] [domain]                             更改伪装网站

进阶:
   dns [...]                                       设置 DNS
   dd, ddel [name...]                              删除多个配置**
   fix [name]                                      修复一个配置
   fix-all                                         修复全部配置
   fix-caddyfile                                   修复 Caddyfile
   fix-config.json                                 修复 config.json
   import                                          导入 sing-box/v2ray 脚本配置

管理:
   un, uninstall                                   卸载
   rollback [--dry-run] [--yes]                    回滚最近一次脚本管理的写入
   u, update [core | sh | caddy] [ver | --latest]  更新; core 默认使用 pinned stable
   u, update core --core-version [ver]             使用指定 sing-box core 版本更新
   U, update.sh                                    更新脚本
   s, status                                       运行状态
   start, stop, restart [caddy]                    启动, 停止, 重启
   t, test                                         测试运行
   reinstall                                       重装脚本

测试:
   debug [name]                                    显示一些 debug 信息, 仅供参考
   gen [...]                                       同等于 add, 但只显示 JSON 内容, 不创建文件, 测试使用
   no-auto-tls [...]                               同等于 add, 但禁止自动配置 TLS, 可用于 *TLS 相关协议
其他:
   bbr                                             启用 BBR, 如果支持
   bin [...]                                       运行 sing-box 命令, 例如: sing-box bin help
   [...] [...]                                     兼容绝大多数的 sing-box 命令, 例如: sing-box generate uuid
   h, help                                         显示此帮助界面

Backup: 修改关键文件前会在 /etc/sing-box/backups/ 创建本地事务备份。
Rollback: 使用 sing-box rollback 恢复最近一次脚本管理的写入。
Version policy: sing-box core 默认使用 pinned stable; 只有显式 --latest 才追 upstream latest。
谨慎使用 del, ddel; 删除前会写入备份事务，但仍应确认目标配置。
反馈问题) https://github.com/ExNG51/sing-box/issues
```
