#!/bin/bash

# 中文注释：判断当前 sing-box core 是否支持 root certificate_providers。
# 只做版本检测，不写入任何生产文件。
cert_supports_certificate_provider() {
    type is_core_version_ge >/dev/null 2>&1 || return 1
    is_core_version_ge "${1:-$is_core_ver}" "1.14.0"
}

# 中文注释：生成 ACME provider tag，保持稳定可预测，并替换非法字符。
# 只做字符串渲染，不写入任何生产文件。
cert_build_acme_provider_tag() {
    local domain=$1

    printf 'acme-%s\n' "${domain//[^A-Za-z0-9_.-]/-}"
}

# 中文注释：为 domain 渲染 ACME 默认 data_directory。
# 当前 sing-box 既有行为固定落在 core 目录下的 acme 子目录。
cert_default_acme_data_directory() {
    printf '%s/acme\n' "${is_core_dir:-/etc/sing-box}"
}

# 中文注释：默认自签证书路径；用于识别 self-signed-insecure profile。
cert_default_self_signed_certificate_path() {
    printf '%s\n' "${is_tls_cer:-${is_core_dir:-/etc/sing-box}/bin/tls.cer}"
}

# 中文注释：默认自签私钥路径；用于识别 self-signed-insecure profile。
cert_default_self_signed_key_path() {
    printf '%s\n' "${is_tls_key:-${is_core_dir:-/etc/sing-box}/bin/tls.key}"
}

# 中文注释：扫描 JSON 内容，识别指定 domain 是否已有 certificate_provider。
# 从 stdin 读取 JSON，只做检测，不写入任何生产文件。
cert_detect_provider_profile_in_json() {
    local domain=$1
    local json

    json=$(cat)
    jq -e --arg domain "$domain" '
        . as $root
        | [
            $root.certificate_providers[]?
            | select(.type == "acme")
            | select(($domain == "") or any(.domain[]?; . == $domain))
            | .tag
        ] as $tags
        | any($root.inbounds[]?;
            (.tls.certificate_provider // "") as $tag
            | ($tags | index($tag)) != null
        )
    ' <<<"$json" >/dev/null 2>&1 || return 1

    printf '%s\n' "acme-provider"
}

# 中文注释：扫描 JSON 内容，识别指定 domain 是否已有 legacy tls.acme。
# 从 stdin 读取 JSON，只做检测，不写入任何生产文件。
cert_detect_legacy_acme_profile_in_json() {
    local domain=$1
    local json

    json=$(cat)
    jq -e --arg domain "$domain" '
        any(.inbounds[]?;
            any(.tls.acme.domain[]?; ($domain == "") or . == $domain)
        )
    ' <<<"$json" >/dev/null 2>&1 || return 1

    printf '%s\n' "legacy-acme"
}

# 中文注释：扫描 JSON 内容，识别指定 domain 是否已有外部文件证书。
# 从 stdin 读取 JSON，只做检测，不写入任何生产文件。
cert_detect_file_cert_profile_in_json() {
    local domain=$1
    local default_cert default_key json

    default_cert=$(cert_default_self_signed_certificate_path)
    default_key=$(cert_default_self_signed_key_path)
    json=$(cat)
    jq -e --arg domain "$domain" --arg default_cert "$default_cert" --arg default_key "$default_key" '
        any(.inbounds[]?;
            (.tls.certificate_path // "") as $cert
            | (.tls.key_path // "") as $key
            | ($cert != "" and $key != "")
            and ($cert != $default_cert or $key != $default_key)
            and (
                $domain == ""
                or (.tls.server_name // "") == $domain
                or ($cert | contains($domain))
                or ($key | contains($domain))
            )
        )
    ' <<<"$json" >/dev/null 2>&1 || return 1

    printf '%s\n' "file-cert"
}

# 中文注释：扫描 JSON 内容，识别当前默认自签证书 profile。
# 从 stdin 读取 JSON，只做检测；客户端通常需要 insecure。
cert_detect_self_signed_profile_in_json() {
    local default_cert default_key json

    default_cert=$(cert_default_self_signed_certificate_path)
    default_key=$(cert_default_self_signed_key_path)
    json=$(cat)
    jq -e --arg default_cert "$default_cert" --arg default_key "$default_key" '
        any(.inbounds[]?;
            (.tls.certificate_path // "") == $default_cert
            and (.tls.key_path // "") == $default_key
        )
    ' <<<"$json" >/dev/null 2>&1 || return 1

    printf '%s\n' "self-signed-insecure"
}

# 中文注释：扫描单份 JSON 内容，按共享证书模式输出 profile。
# 从 stdin 读取 JSON，只做检测，不写入任何生产文件。
cert_detect_profile_in_json() {
    local domain=$1
    local json

    json=$(cat)
    if cert_detect_provider_profile_in_json "$domain" <<<"$json" >/dev/null; then
        printf '%s\n' "acme-provider"
    elif cert_detect_legacy_acme_profile_in_json "$domain" <<<"$json" >/dev/null; then
        printf '%s\n' "legacy-acme"
    elif cert_detect_file_cert_profile_in_json "$domain" <<<"$json" >/dev/null; then
        printf '%s\n' "file-cert"
    elif cert_detect_self_signed_profile_in_json <<<"$json" >/dev/null; then
        printf '%s\n' "self-signed-insecure"
    else
        printf '%s\n' "missing"
    fi
}

# 中文注释：扫描当前 config.json 与 conf/*.json，识别 domain 对应证书 profile。
# 只读取现有配置，不写入任何生产文件。
cert_detect_profile_for_domain() {
    local domain=$1
    local file mode

    for file in "$is_config_json" "$is_conf_dir"/*.json; do
        [[ -f $file ]] || continue
        mode=$(cert_detect_profile_in_json "$domain" <"$file")
        [[ $mode != "missing" ]] && {
            printf '%s\n' "$mode"
            return 0
        }
    done

    printf '%s\n' "missing"
}

# 中文注释：根据当前 core 版本选择 ACME 渲染模式。
# 只做版本判断，不写入任何生产文件。
cert_acme_mode_for_core() {
    if cert_supports_certificate_provider "${1:-$is_core_ver}"; then
        printf '%s\n' "acme-provider"
    else
        printf '%s\n' "legacy-acme"
    fi
}

# 中文注释：渲染当前 inbound 所需 tls JSON 片段。
# 输出为现有 core.sh jq 表达式片段，不直接写入生产配置。
cert_render_tls_json() {
    local mode=$1
    local domain=$2
    local data_directory=${3:-}
    local provider_tag

    [[ $data_directory ]] || data_directory=$(cert_default_acme_data_directory)
    case "$mode" in
    acme-provider)
        provider_tag=$(cert_build_acme_provider_tag "$domain")
        printf 'tls:{enabled:true,certificate_provider:"%s"}\n' "$provider_tag"
        ;;
    legacy-acme)
        printf 'tls:{enabled:true,acme:{domain:["%s"],data_directory:"%s"}}\n' "$domain" "$data_directory"
        ;;
    file-cert)
        [[ $3 && $4 ]] || return 1
        printf 'tls:{enabled:true,certificate_path:"%s",key_path:"%s"}\n' "$3" "$4"
        ;;
    self-signed-insecure)
        printf 'tls:{enabled:true,key_path:"%s",certificate_path:"%s"}\n' \
            "$(cert_default_self_signed_key_path)" \
            "$(cert_default_self_signed_certificate_path)"
        ;;
    *)
        return 1
        ;;
    esac
}

# 中文注释：必要时渲染 root certificate_providers 片段。
# 片段包含前导逗号，供 core.sh 拼接到根 jq 对象；不直接写入生产配置。
cert_render_root_extra_json() {
    local mode=$1
    local domain=$2
    local data_directory=${3:-}
    local provider_tag

    [[ $mode == "acme-provider" ]] || return 0
    [[ $data_directory ]] || data_directory=$(cert_default_acme_data_directory)
    provider_tag=$(cert_build_acme_provider_tag "$domain")
    printf ',certificate_providers:[{type:"acme",tag:"%s",domain:["%s"],data_directory:"%s"}]\n' \
        "$provider_tag" "$domain" "$data_directory"
}

# 中文注释：AnyTLS 从 sing-box 1.12.0 起可用；只做 preflight 检测。
cert_assert_anytls_core_version() {
    is_core_version_ge "$is_core_ver" "1.12.0" || {
        err "当前 sing-box 版本 ($is_core_ver) 不支持 AnyTLS，请先升级 sing-box core 到 1.12.0 或更高版本。"
    }
}

# 中文注释：确认 core ACME capability；只做检测，不写生产配置。
cert_assert_core_acme_capability() {
    local version_output

    version_output=$($is_core_bin version 2>/dev/null || true)

    # 中文注释：如果 version 输出包含 tags 信息，则必须包含 with_acme。
    if grep -qi 'tags:' <<<"$version_output"; then
        grep -qw 'with_acme' <<<"$version_output" || {
            err "当前 sing-box core 未包含 with_acme，无法使用 ACME 自动证书。"
        }
    else
        warn "无法从 sing-box version 输出确认 with_acme；后续将依赖 sing-box check/run 验证。"
    fi
}

# 中文注释：检查 ACME 域名 DNS A / AAAA 是否指向本机；只做检测。
cert_assert_acme_domain_dns() {
    local domain=$1
    local protocol_label=${2:-ACME}
    local server_ipv4 server_ipv6 domain_a_json domain_aaaa_json
    local domain_a_records domain_aaaa_records
    local needs_confirm=

    server_ipv4=$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}')
    server_ipv6=$(_wget -6 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}')
    [[ ! $server_ipv4 && ${ip:-} && $ip != *:* ]] && server_ipv4=$ip
    [[ ! $server_ipv6 && ${ip:-} == *:* ]] && server_ipv6=$ip

    domain_a_json=$(_wget -qO- --header="accept: application/dns-json" "https://one.one.one.one/dns-query?name=$domain&type=A" 2>/dev/null || true)
    domain_aaaa_json=$(_wget -qO- --header="accept: application/dns-json" "https://one.one.one.one/dns-query?name=$domain&type=AAAA" 2>/dev/null || true)
    domain_a_records=$(jq -r '.Answer[]? | select(.type == 1) | .data' <<<"$domain_a_json" 2>/dev/null || true)
    domain_aaaa_records=$(jq -r '.Answer[]? | select(.type == 28) | .data' <<<"$domain_aaaa_json" 2>/dev/null || true)

    [[ ! $domain_a_records && ! $domain_aaaa_records ]] && {
        err "域名 ($domain) 未查询到 A 或 AAAA 记录，${protocol_label} ACME 无法继续。"
    }

    [[ $server_ipv4 ]] && msg "当前服务器 IPv4: $server_ipv4"
    [[ $server_ipv6 ]] && msg "当前服务器 IPv6: $server_ipv6"

    if [[ $domain_a_records ]]; then
        msg "域名 A 记录: $(tr '\n' ' ' <<<"$domain_a_records" | sed 's/[[:space:]]\+$//')"
        if [[ $server_ipv4 ]]; then
            grep -Fxq "$server_ipv4" <<<"$domain_a_records" || {
                err "域名 ($domain) 的 A 记录未指向当前服务器 IPv4 ($server_ipv4)。"
            }
            if grep -Fvx "$server_ipv4" <<<"$domain_a_records" >/dev/null 2>&1; then
                warn "检测到多条 A 记录，其中部分不匹配当前服务器 IPv4 ($server_ipv4)。"
                needs_confirm=1
            fi
        else
            warn "无法确认当前服务器公网 IPv4，A 记录检查只能依赖后续 sing-box check/run。"
            needs_confirm=1
        fi
    fi

    if [[ $domain_aaaa_records ]]; then
        msg "域名 AAAA 记录: $(tr '\n' ' ' <<<"$domain_aaaa_records" | sed 's/[[:space:]]\+$//')"
        if [[ $server_ipv6 ]]; then
            grep -Fxq "$server_ipv6" <<<"$domain_aaaa_records" || {
                err "域名 ($domain) 的 AAAA 记录未指向当前服务器 IPv6 ($server_ipv6)。"
            }
            if grep -Fvx "$server_ipv6" <<<"$domain_aaaa_records" >/dev/null 2>&1; then
                warn "检测到多条 AAAA 记录，其中部分不匹配当前服务器 IPv6 ($server_ipv6)。"
                needs_confirm=1
            fi
        else
            warn "当前服务器未检测到公网 IPv6，但域名存在 AAAA 记录。"
            needs_confirm=1
        fi
    fi

    warn "脚本无法自动确认域名是否为 Cloudflare DNS only。"
    needs_confirm=1

    if [[ $needs_confirm && $is_main_start ]]; then
        ask string y "我已确认域名为 DNS only，且所有 A / AAAA 记录均可到达本机 [y]:"
    elif [[ $needs_confirm ]]; then
        warn "请确认域名为 DNS only，且所有 A / AAAA 记录均可到达本机。"
    fi
}

# 中文注释：检查 ACME TCP/443 本地可用性；不检查 UDP/443，不写生产配置。
cert_assert_acme_tcp_443_available() {
    local protocol_label=${1:-ACME}

    if [[ $(is_tcp_port_used 443) ]]; then
        err "TCP 443 已被占用，${protocol_label} ACME 域名模式无法继续。请先停止占用 443 的服务。"
    fi
}

# 中文注释：执行 ACME 前置检查；不直接写入生产配置。
# 当前 AnyTLS 调用会检查 core 版本、with_acme、DNS、TCP/443、本机防火墙和云安全组提示。
cert_preflight_acme_domain() {
    local protocol=$1
    local domain=$2
    local protocol_label

    protocol_label=$protocol
    [[ ${protocol,,} == "anytls" ]] && protocol_label=AnyTLS
    [[ $domain ]] || err "${protocol_label} ACME 域名不能为空。"

    [[ ${protocol,,} == "anytls" ]] && cert_assert_anytls_core_version
    cert_assert_core_acme_capability
    cert_assert_acme_domain_dns "$domain" "$protocol_label"
    cert_assert_acme_tcp_443_available "$protocol_label"

    load firewall.sh
    ensure_anytls_acme_firewall_443
    warn_anytls_acme_external_firewall
}

# 中文注释：输出证书 profile 摘要，供交互确认或 debug 使用；只读不写。
cert_show_profile_summary() {
    local domain=$1
    local mode

    mode=$(cert_detect_profile_for_domain "$domain")
    if type ui_kv >/dev/null 2>&1; then
        ui_kv "证书域名" "$domain"
        ui_kv "证书模式" "$mode"
    else
        msg "证书域名: $domain"
        msg "证书模式: $mode"
    fi
}
