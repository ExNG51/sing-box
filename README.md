# sing-box 管理脚本

这是一个基于 sing-box 的安装与管理脚本 fork，主要用于个人 VPS 上的 sing-box 部署、配置管理、更新与回滚。

本 fork 偏向稳定和可维护性：默认使用固定的稳定 sing-box core 版本，关键文件写入前会创建本地备份事务，并尽量在配置写入和服务重启失败时给出明确提示。

## 特性

- 安装、更新、卸载 sing-box
- 添加、查看、更改、删除常见 inbound 配置
- 支持 VLESS Reality、TUIC、Trojan、Hysteria2、AnyTLS、Shadowsocks、VMess 等常见配置模板
- 支持二维码与 URL 输出
- 支持本地 backup / rollback
- 默认使用 pinned stable sing-box core
- AnyTLS 域名模式支持 sing-box ACME 自动证书
- 针对 UFW / firewalld 的 TCP 443 放行做了基础处理
- 针对 systemd `ProtectSystem` 环境补充 ACME data directory 可写路径处理

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ExNG51/sing-box/main/install.sh)
```

安装完成后不会自动创建任何代理协议配置。请进入菜单或使用命令手动添加需要的协议。

```bash
sing-box
```

或：

```bash
sb
```

## 基本使用

查看帮助：

```bash
sing-box help
```

查看状态：

```bash
sing-box status
```

添加配置：

```bash
sing-box add
```

添加指定协议：

```bash
sing-box add anytls
sing-box add reality
sing-box add ss
```

查看配置：

```bash
sing-box info
sing-box url
sing-box qr
```

重启服务：

```bash
sing-box restart
```

查看日志：

```bash
sing-box log
```

## 版本策略

脚本默认使用固定的稳定 sing-box core 版本：

```text
v1.13.8
```

如需指定版本：

```bash
sing-box update core --core-version v1.13.8
```

如需跟随上游最新版本：

```bash
sing-box update core --latest
```

`--latest` 可能引入上游 breaking changes，仅在明确需要时使用。

## Backup / Rollback

脚本在修改关键文件前会创建本地备份事务，路径为：

```text
/etc/sing-box/backups/
```

查看最近一次回滚计划：

```bash
sing-box rollback --dry-run
```

执行最近一次回滚：

```bash
sing-box rollback
```

跳过确认执行回滚：

```bash
sing-box rollback --yes
```

rollback 覆盖脚本管理的关键文件，例如 sing-box 配置、部分服务文件、脚本管理的二进制与配置文件。它不回滚系统软件包安装、云厂商安全组、脚本外手动修改的防火墙规则或证书服务外部状态。

脚本会通过带标记的 alias block 管理 `/root/.bashrc`，不会删除 block 外的用户自定义内容。

## AnyTLS ACME 注意事项

AnyTLS 域名模式使用 sing-box 的 ACME 自动证书能力。使用前请确认：

- 域名 A / AAAA 记录指向当前 VPS；
- 如使用 Cloudflare，记录应为 DNS only；
- TCP 443 未被其他服务占用；
- 本机防火墙和云厂商安全组已放行 TCP 443；
- sing-box core 包含 `with_acme`；
- 如 systemd unit 启用了 `ProtectSystem=full/strict`，脚本会为 ACME data directory 添加独立 drop-in，使其可写。

常用检查命令：

```bash
dig +short A your.domain.com
dig +short AAAA your.domain.com
ss -ltnp | grep -E ':(443)\b'
ufw status verbose
systemctl status sing-box --no-pager
journalctl -u sing-box -n 200 --no-pager
```

验证证书：

```bash
openssl s_client -connect your.domain.com:443 -servername your.domain.com -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

## 常用命令

```text
sing-box add [protocol]       添加配置
sing-box info [name]          查看配置
sing-box url [name]           输出 URL
sing-box qr [name]            输出二维码
sing-box change [name]        更改配置
sing-box del [name]           删除配置
sing-box status               查看运行状态
sing-box restart              重启服务
sing-box log                  查看日志
sing-box update core          更新 core
sing-box rollback             回滚最近一次脚本管理的写入
sing-box help                 查看完整帮助
```

## 维护说明

本仓库是个人维护 fork，目标是满足自用 VPS 场景下的稳定部署和可回滚管理。

使用前建议先阅读 `sing-box help`，并在生产环境中谨慎执行删除、更新和回滚操作。
