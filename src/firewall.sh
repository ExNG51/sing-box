#!/bin/bash

detect_firewall_backend() {
    if type -P ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        printf '%s\n' "ufw"
        return 0
    fi

    if type -P firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        printf '%s\n' "firewalld"
        return 0
    fi

    if type -P nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        printf '%s\n' "nftables"
        return 0
    fi

    if type -P iptables >/dev/null 2>&1 && iptables -S INPUT >/dev/null 2>&1; then
        printf '%s\n' "iptables"
        return 0
    fi

    printf '%s\n' "none"
}

allow_ufw_tcp_443() {
    # 中文注释：UFW allow 规则相对幂等，重复执行不应破坏现有策略。
    ufw allow 443/tcp >/dev/null 2>&1 || err "UFW 放行 TCP 443 失败。"
    _green "已通过 UFW 放行 TCP 443。"
}

allow_firewalld_tcp_443() {
    local runtime_allowed=false
    local permanent_allowed=false

    # 中文注释：firewalld 必须同时保证 runtime 与 permanent；runtime-only 状态需要补 permanent 并 reload。
    firewall-cmd --query-port=443/tcp >/dev/null 2>&1 && runtime_allowed=true
    firewall-cmd --permanent --query-port=443/tcp >/dev/null 2>&1 && permanent_allowed=true

    if [[ $runtime_allowed == true && $permanent_allowed == true ]]; then
        _green "firewalld 已放行 TCP 443。"
        return 0
    fi

    if [[ $permanent_allowed != true ]]; then
        firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || {
            err "firewalld 添加 TCP 443 永久规则失败。"
        }
    fi

    firewall-cmd --reload >/dev/null 2>&1 || {
        err "firewalld reload 失败。"
    }

    _green "已通过 firewalld 放行 TCP 443。"
}

warn_manual_firewall_tcp_443() {
    local backend=$1

    warn "检测到 $backend，但脚本不自动修改复杂底层防火墙规则。请确认 TCP 443 入站已放行。"

    case "$backend" in
    nftables)
        msg "参考检查命令：nft list ruleset"
        msg "请按当前 ruleset 结构添加 tcp dport 443 accept。"
        ;;
    iptables)
        msg "临时放行参考：iptables -C INPUT -p tcp --dport 443 -j ACCEPT || iptables -I INPUT -p tcp --dport 443 -j ACCEPT"
        msg "注意：iptables 持久化方式取决于发行版。"
        ;;
    esac

    if [[ $is_main_start ]]; then
        ask string y "我已确认 TCP 443 入站已放行 [y]:"
    fi
}

ensure_anytls_acme_firewall_443() {
    local firewall_backend

    firewall_backend=$(detect_firewall_backend)

    case "$firewall_backend" in
    ufw)
        allow_ufw_tcp_443
        ;;
    firewalld)
        allow_firewalld_tcp_443
        ;;
    nftables | iptables)
        warn_manual_firewall_tcp_443 "$firewall_backend"
        ;;
    none)
        msg "$is_warn 未检测到已启用的 UFW/firewalld；跳过本机防火墙规则修改。"
        ;;
    *)
        warn "无法识别防火墙类型，请手动确认 TCP 443 入站已放行。"
        ;;
    esac
}

warn_anytls_acme_external_firewall() {
    msg "$is_warn 如果服务器位于 AWS / Lightsail / Oracle / Azure / GCP / 阿里云 / 腾讯云等平台，请同时确认云安全组已放行 TCP 443。"
}
