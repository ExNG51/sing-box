#!/bin/bash

# 中文注释：TUIC 专项生命周期模块；只管理 TUIC sing-box 配置，不集成 Port-Hopping 生产对象。

TUIC_TASK_D_NOTICE="Port-Hopping lifecycle integration is reserved for Task D."

# 中文注释：清理 TUIC 模块全局状态，避免多次 CLI / 菜单调用互相污染。
tuic_reset_state() {
    unset tuic_port tuic_uuid tuic_password tuic_domain tuic_tls_mode tuic_requested_tls
    unset tuic_cert_file tuic_key_file tuic_insecure tuic_cc tuic_config_name tuic_config_file
    unset tuic_provider_tag tuic_provider_reused tuic_new_provider tuic_acme_data_dir
    unset tuic_yes tuic_confirm_token tuic_dry_run tuic_tls_changed tuic_password_auto tuic_uuid_auto
    unset tuic_cert_file_arg tuic_key_file_arg
    unset tuic_skip_check tuic_skip_restart tuic_new_json
}

# 中文注释：错误输出兼容被 init.sh 加载和测试直接 source 两种场景。
tuic_fail() {
    if type err >/dev/null 2>&1; then
        err "$*"
    else
        printf '[ERROR] %s\n' "$*" >&2
    fi
    return 1
}

# 中文注释：警告输出兼容 CLI / 测试场景。
tuic_warn() {
    if type warn >/dev/null 2>&1; then
        warn "$*"
    elif type ui_warn >/dev/null 2>&1; then
        ui_warn "$*"
    else
        printf '[WARN] %s\n' "$*" >&2
    fi
}

# 中文注释：按需加载证书模块；测试直接 source 时从当前文件目录回退加载。
tuic_load_cert() {
    type cert_render_tls_json >/dev/null 2>&1 && return 0
    if type load >/dev/null 2>&1; then
        load cert.sh
        return 0
    fi
    # shellcheck source=/dev/null
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cert.sh"
}

# 中文注释：生成 UUID，优先复用系统能力，避免依赖 sing-box core。
tuic_generate_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid
    elif type -P uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        printf '%08x-%04x-%04x-%04x-%012x\n' \
            "$RANDOM$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM$RANDOM$RANDOM"
    fi
}

# 中文注释：生成 URL-safe password，避免客户端 URL 被特殊字符破坏。
tuic_generate_password() {
    local value

    if type -P openssl >/dev/null 2>&1; then
        value=$(openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24)
    fi
    if [[ ! $value && -r /dev/urandom ]]; then
        value=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    fi
    [[ ! $value ]] && value="$(date +%s)${RANDOM}${RANDOM}${RANDOM}"
    printf '%s\n' "$value"
}

# 中文注释：URL encode 凭据；auto password 已是 URL-safe，但手动 password 仍需编码。
tuic_urlencode() {
    local value=$1
    local i char code out=
    local LC_ALL=C

    for ((i = 0; i < ${#value}; i++)); do
        char=${value:i:1}
        case "$char" in
        [a-zA-Z0-9.~_-])
            out+=$char
            ;;
        *)
            printf -v code '%%%02X' "'$char"
            out+=$code
            ;;
        esac
    done
    printf '%s' "$out"
}

# 中文注释：校验 congestion_control，只允许 sing-box TUIC 常用值。
tuic_validate_cc() {
    case "${1:-}" in
    bbr | cubic | new_reno) return 0 ;;
    *) return 1 ;;
    esac
}

# 中文注释：校验端口格式。
tuic_validate_port_number() {
    local value=$1

    [[ $value =~ ^[1-9][0-9]*$ ]] && [[ $value -le 65535 ]]
}

# 中文注释：校验 UUID 格式；兼容未加载 core.sh 的测试环境。
tuic_validate_uuid() {
    local value=$1

    [[ $value =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# 中文注释：校验域名格式；只做基础校验，不做 DNS / ACME 可达性检查。
tuic_validate_domain() {
    local value=$1

    [[ $value =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z0-9.-]+$ ]]
}

# 中文注释：解析 add 参数；不写生产文件。
tuic_parse_add_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --port | -p)
            [[ $2 ]] || return 1
            tuic_port=$2
            shift 2
            ;;
        --uuid)
            [[ $2 ]] || return 1
            tuic_uuid=$2
            [[ $tuic_uuid == auto ]] && tuic_uuid_auto=1
            shift 2
            ;;
        --password)
            [[ $2 ]] || return 1
            tuic_password=$2
            [[ $tuic_password == auto ]] && tuic_password_auto=1
            shift 2
            ;;
        --domain | -d)
            [[ $2 ]] || return 1
            tuic_domain=$2
            tuic_tls_changed=1
            shift 2
            ;;
        --tls)
            [[ $2 ]] || return 1
            tuic_requested_tls=$2
            tuic_tls_changed=1
            shift 2
            ;;
        --cert-file)
            [[ $2 ]] || return 1
            tuic_cert_file=$2
            tuic_cert_file_arg=1
            tuic_tls_changed=1
            shift 2
            ;;
        --key-file)
            [[ $2 ]] || return 1
            tuic_key_file=$2
            tuic_key_file_arg=1
            tuic_tls_changed=1
            shift 2
            ;;
        --insecure)
            tuic_insecure=1
            tuic_tls_changed=1
            shift
            ;;
        --cc)
            [[ $2 ]] || return 1
            tuic_cc=$2
            shift 2
            ;;
        --yes)
            tuic_yes=1
            shift
            ;;
        --confirm)
            [[ $2 ]] || return 1
            tuic_confirm_token=$2
            shift 2
            ;;
        --dry-run)
            tuic_dry_run=1
            shift
            ;;
        *)
            tuic_fail "无法识别 TUIC 参数: $1"
            return 1
            ;;
        esac
    done
}

# 中文注释：解析 change / migrate 参数；未提供的字段保留现有配置值。
tuic_parse_change_args() {
    tuic_parse_add_args "$@"
}

# 中文注释：为未指定端口的 CLI 自动选择端口；交互路径由调用方询问。
tuic_prepare_port_default() {
    [[ $tuic_port == auto ]] && tuic_port=
    if [[ ! $tuic_port ]]; then
        if [[ ${is_main_start:-} ]]; then
            ui_read_or_cancel tuic_port "请输入 TUIC UDP 监听端口（q 取消）： " || return $?
        elif type get_port >/dev/null 2>&1; then
            get_port
            tuic_port=$tmp_port
        else
            tuic_port=10443
        fi
    fi

    tuic_validate_port_number "$tuic_port" || {
        tuic_fail "TUIC 端口无效: $tuic_port"
        return 1
    }
}

# 中文注释：为新增或修改流程准备 UUID / password / cc。
tuic_prepare_credentials() {
    if [[ ! $tuic_uuid || $tuic_uuid == auto ]]; then
        tuic_uuid=$(tuic_generate_uuid)
    else
        tuic_validate_uuid "$tuic_uuid" || {
            tuic_fail "TUIC UUID 无效: $tuic_uuid"
            return 1
        }
    fi

    if [[ ! $tuic_password || $tuic_password == auto ]]; then
        tuic_password=$(tuic_generate_password)
        [[ $tuic_password == "$tuic_uuid" ]] && tuic_password=$(tuic_generate_password)
    fi
    [[ $tuic_password ]] || {
        tuic_fail "TUIC password 不能为空。"
        return 1
    }

    tuic_cc=${tuic_cc:-bbr}
    tuic_validate_cc "$tuic_cc" || {
        tuic_fail "TUIC congestion_control 仅支持 bbr / cubic / new_reno。"
        return 1
    }
}

# 中文注释：选择 TUIC TLS 证书模式；必要时复用 root certificate_provider。
tuic_prepare_tls_mode() {
    local existing_tag acme_mode

    tuic_load_cert

    if [[ $tuic_insecure ]]; then
        tuic_tls_mode=self-signed-insecure
        tuic_domain=
        return 0
    fi

    if [[ $tuic_requested_tls == acme && ! $tuic_domain ]]; then
        tuic_fail "TUIC --tls acme 必须同时提供 --domain。"
        return 1
    fi

    if [[ $tuic_requested_tls == acme || ( $tuic_domain && ! $tuic_cert_file_arg && ! $tuic_key_file_arg && ! $tuic_insecure && $tuic_tls_changed ) ]]; then
        tuic_cert_file=
        tuic_key_file=
    elif [[ $tuic_cert_file_arg || $tuic_key_file_arg ]]; then
        [[ $tuic_cert_file && $tuic_key_file ]] || {
            tuic_fail "file-cert 模式必须同时提供 --cert-file 与 --key-file。"
            return 1
        }
        [[ $tuic_cert_file == /* && $tuic_key_file == /* ]] || {
            tuic_fail "file-cert 路径必须是绝对路径。"
            return 1
        }
        [[ $tuic_domain ]] || {
            tuic_fail "file-cert 模式必须提供 --domain 作为 TLS server_name。"
            return 1
        }
        tuic_tls_mode=file-cert
        return 0
    fi

    if [[ $tuic_requested_tls && $tuic_requested_tls != acme ]]; then
        tuic_fail "TUIC --tls 目前仅支持 acme。"
        return 1
    fi

    if [[ $tuic_domain ]]; then
        tuic_validate_domain "$tuic_domain" || {
            tuic_fail "TUIC domain 无效: $tuic_domain"
            return 1
        }
        existing_tag=
        if cert_supports_certificate_provider "${is_core_ver:-}" 2>/dev/null; then
            existing_tag=$(cert_detect_root_provider_for_domain "$tuic_domain" 2>/dev/null || true)
        fi
        if [[ $existing_tag ]]; then
            tuic_tls_mode=acme-provider
            tuic_provider_tag=$existing_tag
            tuic_provider_reused=1
            tuic_new_provider=
            return 0
        fi

        acme_mode=$(cert_acme_mode_for_core "${is_core_ver:-}")
        tuic_tls_mode=$acme_mode
        tuic_acme_data_dir=${tuic_acme_data_dir:-$(cert_default_acme_data_directory)}
        if [[ $tuic_tls_mode == acme-provider ]]; then
            tuic_provider_tag=$(cert_build_acme_provider_tag "$tuic_domain")
            tuic_new_provider=1
        fi
        return 0
    fi

    tuic_tls_mode=self-signed-insecure
}

# 中文注释：准备新增 TUIC 配置状态。
tuic_prepare_add_state() {
    tuic_prepare_port_default || return $?
    tuic_prepare_credentials || return 1
    tuic_prepare_tls_mode || return 1
}

# 中文注释：准备修改 TUIC 配置状态；只有 TLS 参数变化时才重选证书模式。
tuic_prepare_change_state() {
    tuic_prepare_port_default || return $?
    tuic_prepare_credentials || return 1
    if [[ $tuic_tls_changed ]]; then
        tuic_prepare_tls_mode || return 1
    fi
}

# 中文注释：根据 TUIC 端口做协议感知冲突检测；当前端口幂等放行。
tuic_validate_port_available() {
    local new_port=$1
    local current_port=${2:-}

    [[ $new_port && $new_port == "$current_port" ]] && return 0
    type is_listen_port_used_for_protocol >/dev/null 2>&1 || return 0
    is_listen_port_used_for_protocol TUIC "$new_port" && return 1
    return 0
}

# 中文注释：TUIC 使用 UDP/443 时执行本机与云防火墙提示。
tuic_preflight_udp_443_if_needed() {
    [[ ${is_gen:-} || ${tuic_dry_run:-} || $tuic_port != 443 ]] && return 0

    if type load >/dev/null 2>&1; then
        load firewall.sh
    else
        # shellcheck source=/dev/null
        . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/firewall.sh"
    fi
    ensure_udp_443_firewall
    warn_udp_443_external_firewall
}

# 中文注释：只有需要新建 ACME provider / legacy ACME 时才执行 ACME preflight。
tuic_preflight_acme_if_needed() {
    [[ ${is_gen:-} || ${tuic_dry_run:-} ]] && return 0
    case "$tuic_tls_mode" in
    acme-provider)
        [[ $tuic_provider_reused ]] && return 0
        ;;
    legacy-acme)
        ;;
    *)
        return 0
        ;;
    esac

    tuic_load_cert
    cert_preflight_acme_domain tuic "$tuic_domain"
}

# 中文注释：生成 TUIC 配置文件名。
tuic_default_config_name() {
    if [[ $tuic_domain ]]; then
        printf 'tuic-%s.json\n' "$tuic_domain"
    else
        printf 'tuic-%s.json\n' "$tuic_port"
    fi
}

# 中文注释：渲染 TUIC inbound JSON，供 add/change/migrate 和测试复用。
tuic_render_inbound_json() {
    local tag cert_path key_path data_dir provider_tag new_provider

    tuic_load_cert
    tag=${tuic_config_name:-$(tuic_default_config_name)}
    cert_path=$tuic_cert_file
    key_path=$tuic_key_file
    data_dir=${tuic_acme_data_dir:-$(cert_default_acme_data_directory)}
    provider_tag=${tuic_provider_tag:-$(cert_build_acme_provider_tag "$tuic_domain")}
    new_provider=false
    [[ $tuic_tls_mode == acme-provider && $tuic_new_provider ]] && new_provider=true

    [[ $tuic_tls_mode == self-signed-insecure ]] && {
        cert_path=$(cert_default_self_signed_certificate_path)
        key_path=$(cert_default_self_signed_key_path)
    }

    jq -n \
        --arg tag "$tag" \
        --argjson port "$tuic_port" \
        --arg uuid "$tuic_uuid" \
        --arg password "$tuic_password" \
        --arg cc "$tuic_cc" \
        --arg mode "$tuic_tls_mode" \
        --arg domain "${tuic_domain:-}" \
        --arg cert_path "${cert_path:-}" \
        --arg key_path "${key_path:-}" \
        --arg provider_tag "${provider_tag:-}" \
        --arg data_dir "$data_dir" \
        --arg new_provider "$new_provider" '
        {
          inbounds: [
            {
              tag: $tag,
              type: "tuic",
              listen: "::",
              listen_port: $port,
              users: [{uuid: $uuid, password: $password}],
              congestion_control: $cc,
              tls: {enabled: true, alpn: ["h3"]}
            }
          ]
        }
        | if $domain != "" then .inbounds[0].tls.server_name = $domain else . end
        | if $mode == "acme-provider" then
            .inbounds[0].tls.certificate_provider = $provider_tag
            | if $new_provider == "true" then
                .certificate_providers = [{type: "acme", tag: $provider_tag, domain: [$domain], data_directory: $data_dir}]
              else . end
          elif $mode == "legacy-acme" then
            .inbounds[0].tls.acme = {domain: [$domain], data_directory: $data_dir}
          elif $mode == "file-cert" or $mode == "self-signed-insecure" then
            .inbounds[0].tls.certificate_path = $cert_path
            | .inbounds[0].tls.key_path = $key_path
          else . end
    '
}

# 中文注释：从 JSON 渲染 TUIC 客户端 URL；domain 证书不带 allow_insecure。
tuic_render_client_url() {
    local json=$1
    local uuid password port cc domain cert_path key_path endpoint fragment query insecure
    local default_cert default_key

    tuic_load_cert
    default_cert=$(cert_default_self_signed_certificate_path)
    default_key=$(cert_default_self_signed_key_path)

    uuid=$(jq -r '.inbounds[0].users[0].uuid // ""' <<<"$json")
    password=$(jq -r '.inbounds[0].users[0].password // ""' <<<"$json")
    port=$(jq -r '.inbounds[0].listen_port // ""' <<<"$json")
    cc=$(jq -r '.inbounds[0].congestion_control // "bbr"' <<<"$json")
    domain=$(jq -r '.inbounds[0].tls.server_name // ""' <<<"$json")
    cert_path=$(jq -r '.inbounds[0].tls.certificate_path // ""' <<<"$json")
    key_path=$(jq -r '.inbounds[0].tls.key_path // ""' <<<"$json")

    endpoint=$domain
    if [[ ! $endpoint ]]; then
        if [[ ${ip:-} ]]; then
            endpoint=$ip
        elif [[ ! ${is_gen:-} ]] && type get_ip >/dev/null 2>&1; then
            get_ip
            endpoint=$ip
        fi
    fi
    [[ ! $endpoint ]] && endpoint=ip
    [[ $endpoint == *:* && $endpoint != \[*\] ]] && endpoint="[$endpoint]"

    insecure=
    [[ $cert_path == "$default_cert" && $key_path == "$default_key" ]] && insecure=1

    query="alpn=h3"
    [[ $insecure ]] && query+="&allow_insecure=1"
    query+="&congestion_control=$(tuic_urlencode "$cc")"

    fragment="sing-box-tuic-${domain:-${endpoint//[\[\]:]/-}}"
    printf 'tuic://%s:%s@%s:%s?%s#%s\n' \
        "$(tuic_urlencode "$uuid")" \
        "$(tuic_urlencode "$password")" \
        "$endpoint" \
        "$port" \
        "$query" \
        "$(tuic_urlencode "$fragment")"
}

# 中文注释：定位 TUIC 配置文件；支持绝对路径、相对路径、conf basename。
tuic_resolve_config_path() {
    local name=${1:-}
    local file

    if [[ ! $name ]]; then
        for file in "${is_conf_dir:-/etc/sing-box/conf}"/*.json; do
            [[ -f $file ]] || continue
            jq -e '.inbounds[0].type == "tuic"' "$file" >/dev/null 2>&1 && {
                printf '%s\n' "$file"
                return 0
            }
        done
        return 1
    fi

    if [[ $name == */* && -f $name ]]; then
        printf '%s\n' "$name"
        return 0
    fi
    if [[ -f $name ]]; then
        printf '%s\n' "$name"
        return 0
    fi
    file="${is_conf_dir:-/etc/sing-box/conf}/$name"
    [[ -f $file ]] && {
        printf '%s\n' "$file"
        return 0
    }
    [[ $name != *.json ]] && file="${is_conf_dir:-/etc/sing-box/conf}/$name.json"
    [[ -f $file ]] && {
        printf '%s\n' "$file"
        return 0
    }
    return 1
}

# 中文注释：读取 TUIC 配置到模块状态。
tuic_read_config() {
    local target=$1
    local json provider default_cert default_key

    tuic_config_file=$(tuic_resolve_config_path "$target") || {
        tuic_fail "未找到 TUIC 配置: ${target:-<auto>}"
        return 1
    }
    jq -e '.inbounds[0].type == "tuic"' "$tuic_config_file" >/dev/null 2>&1 || {
        tuic_fail "配置不是 TUIC inbound: $tuic_config_file"
        return 1
    }

    tuic_load_cert
    json=$(cat "$tuic_config_file")
    tuic_config_name=$(basename "$tuic_config_file")
    tuic_port=$(jq -r '.inbounds[0].listen_port // ""' <<<"$json")
    tuic_uuid=$(jq -r '.inbounds[0].users[0].uuid // ""' <<<"$json")
    tuic_password=$(jq -r '.inbounds[0].users[0].password // ""' <<<"$json")
    tuic_cc=$(jq -r '.inbounds[0].congestion_control // "bbr"' <<<"$json")
    tuic_domain=$(jq -r '.inbounds[0].tls.server_name // ""' <<<"$json")
    tuic_cert_file=$(jq -r '.inbounds[0].tls.certificate_path // ""' <<<"$json")
    tuic_key_file=$(jq -r '.inbounds[0].tls.key_path // ""' <<<"$json")
    provider=$(jq -r '.inbounds[0].tls.certificate_provider // ""' <<<"$json")
    default_cert=$(cert_default_self_signed_certificate_path)
    default_key=$(cert_default_self_signed_key_path)

    if [[ $provider ]]; then
        tuic_tls_mode=acme-provider
        tuic_provider_tag=$provider
        [[ ! $tuic_domain ]] && tuic_domain=$(jq -r --arg provider "$provider" '.certificate_providers[]? | select(.tag == $provider) | .domain[0] // empty' <<<"$json" | head -n 1)
    elif jq -e '.inbounds[0].tls.acme' <<<"$json" >/dev/null 2>&1; then
        tuic_tls_mode=legacy-acme
        tuic_domain=$(jq -r '.inbounds[0].tls.acme.domain[0] // ""' <<<"$json")
    elif [[ $tuic_cert_file == "$default_cert" && $tuic_key_file == "$default_key" ]]; then
        tuic_tls_mode=self-signed-insecure
    elif [[ $tuic_cert_file && $tuic_key_file ]]; then
        tuic_tls_mode=file-cert
    else
        tuic_tls_mode=unknown
    fi
}

# 中文注释：隐藏敏感值，只在 info 摘要中展示长度线索。
tuic_mask_secret() {
    local value=$1
    [[ $value ]] || {
        printf '-\n'
        return
    }
    printf '****\n'
}

# 中文注释：输出 TUIC 摘要；默认不裸露 UUID/password。
tuic_show_summary() {
    local source address_mode

    address_mode=ip
    [[ $tuic_domain ]] && address_mode=domain
    case "$tuic_tls_mode" in
    acme-provider) source=${tuic_provider_tag:-certificate_provider} ;;
    legacy-acme) source=tls.acme ;;
    file-cert) source="$tuic_cert_file" ;;
    self-signed-insecure) source=self-signed ;;
    *) source=unknown ;;
    esac

    ui_kv "协议" "TUIC"
    ui_kv "监听协议" "UDP"
    ui_kv "监听端口" "$tuic_port"
    ui_kv "地址模式" "$address_mode"
    ui_kv "域名" "${tuic_domain:-"-"}"
    ui_kv "TLS 模式" "$tuic_tls_mode"
    ui_kv "证书来源" "$source"
    ui_kv "UUID" "$(tuic_mask_secret "$tuic_uuid")"
    ui_kv "Password" "$(tuic_mask_secret "$tuic_password")"
    ui_kv "拥塞控制" "$tuic_cc"
    ui_kv "Port-Hopping" "not integrated in Task C"
}

# 中文注释：敏感 URL 输出提醒；提醒走 stderr，URL 主体保持 stdout。
tuic_sensitive_warning() {
    if type sensitive_output_warning >/dev/null 2>&1; then
        sensitive_output_warning
    elif type ui_warn >/dev/null 2>&1; then
        ui_warn "下面会显示包含敏感凭据的客户端配置，请避免在共享屏幕、日志或工单中泄露。"
    else
        printf '[WARN] 下面会显示包含敏感凭据的客户端配置，请避免在共享屏幕、日志或工单中泄露。\n' >&2
    fi
    printf '\n' >&2
}

# 中文注释：尽可能执行 sing-box check；缺少 core 二进制时只警告降级。
tuic_check_pending_config() {
    [[ ${tuic_skip_check:-} || ${is_gen:-} || ${tuic_dry_run:-} ]] && return 0
    [[ ${is_core_bin:-} && -x $is_core_bin ]] || {
        tuic_warn "未找到可执行 sing-box core，跳过配置 check。"
        return 0
    }
    type check_pending_server_config >/dev/null 2>&1 || return 0
    check_pending_server_config
}

# 中文注释：生产写入失败后尝试 rollback，至少保证新配置被移除。
tuic_rollback_after_failure() {
    if type rollback_latest_backup >/dev/null 2>&1; then
        rollback_latest_backup --yes || true
    elif [[ ${tuic_config_file:-} && -f $tuic_config_file && $(type -t safe_remove_path) ]]; then
        safe_remove_path "$tuic_config_file" || true
    fi
}

# 中文注释：写入或更新 TUIC 配置，并执行 check + restart + rollback。
tuic_commit_upsert() {
    local operation=${1:-tuic-write}
    local should_finalize=false

    is_new_json=$tuic_new_json
    is_config_name=$tuic_config_name
    is_json_file=$tuic_config_file

    tuic_check_pending_config || {
        tuic_fail "sing-box 配置检查失败，未写入 TUIC 配置。"
        return 1
    }

    [[ ${is_gen:-} || ${tuic_dry_run:-} ]] && {
        jq . <<<"$tuic_new_json"
        return 0
    }

    begin_backup_transaction_if_needed "$operation" && should_finalize=true
    write_server_config_json_if_missing || {
        tuic_rollback_after_failure
        tuic_fail "写入基础 config.json 失败，已尝试回滚。"
        return 1
    }
    safe_write_file "$tuic_config_file" "$tuic_new_json" || {
        tuic_rollback_after_failure
        tuic_fail "写入 TUIC 配置失败，已尝试回滚。"
        return 1
    }

    if [[ ! ${tuic_skip_restart:-} ]]; then
        if type restart_core_and_verify >/dev/null 2>&1; then
            restart_core_and_verify || {
                tuic_rollback_after_failure
                tuic_fail "TUIC 配置导致 sing-box 启动失败，已尝试回滚。"
                return 1
            }
        else
            manage restart &
        fi
    fi

    [[ $should_finalize == true || ${IS_BACKUP_ACTIVE:-} == true ]] && finalize_backup_transaction
}

# 中文注释：添加 TUIC 配置。
tuic_add() {
    tuic_reset_state
    tuic_parse_add_args "$@" || return 1
    tuic_prepare_add_state || return 1

    tuic_validate_port_available "$tuic_port" "" || {
        tuic_fail "UDP $tuic_port 已被占用，无法添加 TUIC。"
        return 1
    }
    tuic_preflight_udp_443_if_needed || return 1
    tuic_preflight_acme_if_needed || return 1

    tuic_config_name=$(tuic_default_config_name)
    tuic_config_file="${is_conf_dir:-/etc/sing-box/conf}/$tuic_config_name"
    [[ -e $tuic_config_file && ! $tuic_yes ]] && {
        tuic_fail "TUIC 配置已存在: $tuic_config_file"
        return 1
    }
    tuic_new_json=$(tuic_render_inbound_json) || return 1
    tuic_commit_upsert add-tuic || return 1

    [[ ${is_gen:-} || ${tuic_dry_run:-} ]] && return 0
    ui_blank
    tuic_show_summary
    tuic_sensitive_warning
    tuic_render_client_url "$tuic_new_json"
    [[ $tuic_tls_mode == self-signed-insecure ]] && tuic_warn "当前 TUIC 使用自签 insecure 模式，仅建议测试或兼容场景使用。"
}

# 中文注释：显示单个或全部 TUIC 配置摘要。
tuic_info() {
    local target=${1:-}
    local file

    if [[ ! $target ]]; then
        for file in "${is_conf_dir:-/etc/sing-box/conf}"/*.json; do
            [[ -f $file ]] || continue
            jq -e '.inbounds[0].type == "tuic"' "$file" >/dev/null 2>&1 || continue
            tuic_reset_state
            tuic_read_config "$file" || return 1
            ui_blank
            ui_print ">>> $tuic_config_name"
            tuic_show_summary
        done
        return 0
    fi

    tuic_reset_state
    tuic_read_config "$target" || return 1
    tuic_show_summary
}

# 中文注释：输出 TUIC 客户端 URL。
tuic_url() {
    local target=$1
    local json

    [[ $target ]] || {
        tuic_fail "请指定 TUIC 配置文件。"
        return 1
    }
    tuic_reset_state
    tuic_read_config "$target" || return 1
    json=$(cat "$tuic_config_file")
    tuic_sensitive_warning
    tuic_render_client_url "$json"
}

# 中文注释：修改 TUIC 配置；只改当前配置文件，不触碰 Port-Hopping 生产对象。
tuic_change() {
    local target=$1
    local current_port

    [[ $target ]] || {
        tuic_fail "请指定 TUIC 配置文件。"
        return 1
    }
    shift
    tuic_reset_state
    tuic_read_config "$target" || return 1
    current_port=$tuic_port
    tuic_parse_change_args "$@" || return 1
    tuic_prepare_change_state || return 1
    tuic_validate_port_available "$tuic_port" "$current_port" || {
        tuic_fail "UDP $tuic_port 已被占用，无法修改 TUIC。"
        return 1
    }
    tuic_preflight_udp_443_if_needed || return 1
    tuic_preflight_acme_if_needed || return 1

    tuic_new_json=$(tuic_render_inbound_json) || return 1
    tuic_commit_upsert change-tuic || return 1
    ui_blank
    tuic_show_summary
    ui_blank
    ui_dim "$TUIC_TASK_D_NOTICE"
}

# 中文注释：删除前确认；CLI 必须显式 --yes 或 --confirm DELETE。
tuic_confirm_delete() {
    [[ $tuic_yes || $tuic_confirm_token == DELETE ]] && return 0
    if [[ ${is_main_start:-} ]]; then
        ui_blank
        ui_print ">>> 删除 TUIC 配置确认"
        ui_warn "此操作只删除 TUIC sing-box 配置，不删除 Port-Hopping 对象。"
        ui_kv "配置文件" "$tuic_config_file"
        ui_blank
        ui_confirm_token "确认删除该 TUIC 配置？" "DELETE" || {
            ui_warn "已取消删除。"
            return 1
        }
        return 0
    fi
    tuic_fail "删除 TUIC 配置需要 --yes 或 --confirm DELETE。"
    return 1
}

# 中文注释：删除后尽可能检查剩余配置。
tuic_check_after_delete() {
    local tmp_conf_dir tmp_config_json check_log base

    [[ ${tuic_skip_check:-} || ${is_gen:-} || ${tuic_dry_run:-} ]] && return 0
    [[ ${is_core_bin:-} && -x $is_core_bin ]] || return 0
    tmp_conf_dir=$(mktemp -d "${TMPDIR:-/tmp}/sing-box-tuic-delete.XXXXXX") || return 1
    tmp_config_json=$(mktemp "${TMPDIR:-/tmp}/sing-box-config-delete.XXXXXX") || {
        rm -rf "$tmp_conf_dir"
        return 1
    }
    check_log=$(mktemp "${TMPDIR:-/tmp}/sing-box-check-delete.XXXXXX") || {
        rm -rf "$tmp_conf_dir"
        rm -f "$tmp_config_json"
        return 1
    }
    cp -a "${is_conf_dir:-/etc/sing-box/conf}"/. "$tmp_conf_dir"/ 2>/dev/null || true
    base=$(basename "$tuic_config_file")
    rm -f "$tmp_conf_dir/$base"
    render_pending_server_config_json >"$tmp_config_json" || {
        rm -rf "$tmp_conf_dir"
        rm -f "$tmp_config_json" "$check_log"
        return 1
    }
    if ! "$is_core_bin" check -c "$tmp_config_json" -C "$tmp_conf_dir" >"$check_log" 2>&1; then
        cat "$check_log"
        rm -rf "$tmp_conf_dir"
        rm -f "$tmp_config_json" "$check_log"
        return 1
    fi
    rm -rf "$tmp_conf_dir"
    rm -f "$tmp_config_json" "$check_log"
}

# 中文注释：删除 TUIC 配置，不触碰 Port-Hopping 生产对象。
tuic_delete() {
    local target=$1
    local should_finalize=false

    [[ $target ]] || {
        tuic_fail "请指定 TUIC 配置文件。"
        return 1
    }
    shift
    tuic_reset_state
    tuic_read_config "$target" || return 1
    tuic_parse_add_args "$@" || return 1
    tuic_confirm_delete || return 1
    tuic_check_after_delete || {
        tuic_fail "删除后的 sing-box 配置检查失败，未删除 TUIC 配置。"
        return 1
    }
    [[ ${tuic_dry_run:-} ]] && return 0

    begin_backup_transaction_if_needed delete-tuic && should_finalize=true
    safe_remove_path "$tuic_config_file" || {
        tuic_rollback_after_failure
        tuic_fail "删除 TUIC 配置失败，已尝试回滚。"
        return 1
    }
    if [[ ! ${tuic_skip_restart:-} ]]; then
        if type restart_core_and_verify >/dev/null 2>&1; then
            restart_core_and_verify || {
                tuic_rollback_after_failure
                tuic_fail "删除 TUIC 后 sing-box 启动失败，已尝试回滚。"
                return 1
            }
        else
            manage restart &
        fi
    fi
    [[ $should_finalize == true || ${IS_BACKUP_ACTIVE:-} == true ]] && finalize_backup_transaction
    ui_blank
    ui_kv "已删除" "$tuic_config_file"
    ui_dim "$TUIC_TASK_D_NOTICE"
    ui_dim "如果该 TUIC 曾手动配置 Port-Hopping，请在 Task D 集成前人工确认 nftables/systemd/UFW 残留。"
}

# 中文注释：迁移旧 TUIC 配置到 domain cert 或独立 password；不做批量迁移。
tuic_migrate() {
    local target=$1

    [[ $target ]] || {
        tuic_fail "请指定 TUIC 配置文件。"
        return 1
    }
    shift
    tuic_reset_state
    tuic_read_config "$target" || return 1
    tuic_parse_change_args "$@" || return 1
    tuic_prepare_change_state || return 1
    tuic_validate_port_available "$tuic_port" "$tuic_port" || return 1
    tuic_preflight_udp_443_if_needed || return 1
    tuic_preflight_acme_if_needed || return 1
    tuic_new_json=$(tuic_render_inbound_json) || return 1
    tuic_commit_upsert migrate-tuic || return 1

    ui_blank
    tuic_show_summary
    tuic_sensitive_warning
    tuic_render_client_url "$tuic_new_json"
    ui_dim "$TUIC_TASK_D_NOTICE"
}

# 中文注释：统计目录内 TUIC 配置，输出机器可测 JSON。
tuic_audit_json() {
    local dir=${1:-${is_conf_dir:-/etc/sing-box/conf}}
    local file json default_cert default_key
    local total=0 insecure=0 domain_cert=0 password_equals_uuid=0 udp_443=0

    tuic_load_cert
    default_cert=$(cert_default_self_signed_certificate_path)
    default_key=$(cert_default_self_signed_key_path)
    for file in "$dir"/*.json; do
        [[ -f $file ]] || continue
        jq -e '.inbounds[0].type == "tuic"' "$file" >/dev/null 2>&1 || continue
        json=$(cat "$file")
        total=$((total + 1))
        [[ $(jq -r '.inbounds[0].listen_port // empty' <<<"$json") == 443 ]] && udp_443=$((udp_443 + 1))
        [[ $(jq -r '.inbounds[0].users[0].uuid // empty' <<<"$json") == "$(jq -r '.inbounds[0].users[0].password // empty' <<<"$json")" ]] && password_equals_uuid=$((password_equals_uuid + 1))
        if [[ $(jq -r '.inbounds[0].tls.certificate_path // ""' <<<"$json") == "$default_cert" && $(jq -r '.inbounds[0].tls.key_path // ""' <<<"$json") == "$default_key" ]]; then
            insecure=$((insecure + 1))
        elif jq -e '.inbounds[0].tls.server_name and (.inbounds[0].tls.certificate_provider or .inbounds[0].tls.acme or .inbounds[0].tls.certificate_path)' <<<"$json" >/dev/null 2>&1; then
            domain_cert=$((domain_cert + 1))
        fi
    done

    jq -n \
        --argjson total "$total" \
        --argjson insecure "$insecure" \
        --argjson domain_cert "$domain_cert" \
        --argjson password_equals_uuid "$password_equals_uuid" \
        --argjson udp_443 "$udp_443" \
        '{total:$total,insecure:$insecure,domain_cert:$domain_cert,password_equals_uuid:$password_equals_uuid,udp_443:$udp_443,port_hopping:"not integrated"}'
}

# 中文注释：只读审计当前 TUIC 配置，不修改任何文件。
tuic_audit() {
    local audit

    audit=$(tuic_audit_json "${1:-${is_conf_dir:-/etc/sing-box/conf}}") || return 1
    ui_kv "TUIC 配置数量" "$(jq -r '.total' <<<"$audit")"
    ui_kv "insecure TUIC" "$(jq -r '.insecure' <<<"$audit")"
    ui_kv "domain cert TUIC" "$(jq -r '.domain_cert' <<<"$audit")"
    ui_kv "password == uuid" "$(jq -r '.password_equals_uuid' <<<"$audit")"
    ui_kv "UDP/443 TUIC" "$(jq -r '.udp_443' <<<"$audit")"
    ui_kv "Port-Hopping" "not integrated"
}

# 中文注释：列出当前 TUIC 配置。
tuic_detect_config() {
    local file

    for file in "${is_conf_dir:-/etc/sing-box/conf}"/*.json; do
        [[ -f $file ]] || continue
        jq -e '.inbounds[0].type == "tuic"' "$file" >/dev/null 2>&1 || continue
        printf '%s\n' "$(basename "$file")"
    done
}

# 中文注释：构建 TUIC 菜单状态行。
tuic_menu_status_line() {
    local count cert_count udp443

    count=$(tuic_detect_config | sed '/^$/d' | wc -l | tr -d ' ')
    cert_count=$(for file in "${is_conf_dir:-/etc/sing-box/conf}"/*.json; do [[ -f $file ]] && jq -r '.certificate_providers[]?.tag' "$file" 2>/dev/null; done | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
    if type is_udp_port_used >/dev/null 2>&1; then
        if is_udp_port_used 443 >/dev/null 2>&1; then
            udp443=used
        else
            udp443=free
        fi
    else
        udp443=unknown
    fi
    printf 'TUIC configs: %s | UDP/443: %s | Cert profiles: %s\n' "${count:-0}" "$udp443" "${cert_count:-0}"
}

# 中文注释：TUIC 子菜单；CLI 路径不会调用 clear/pause。
tuic_menu() {
    local choice config

    is_main_start=1
    while :; do
        ui_clear
        ui_title "TUIC 专项管理" "$is_sh_ver"
        ui_dim "$(tuic_menu_status_line)"
        ui_blank
        ui_print "请选择操作："
        ui_blank
        ui_menu_item 1 "查看 TUIC 配置列表"
        ui_menu_item 2 "添加 TUIC 配置"
        ui_menu_item 3 "查看 TUIC 客户端 URL"
        ui_menu_item 4 "修改 TUIC 配置"
        ui_menu_item 5 "审计 TUIC 配置"
        ui_menu_item 6 "删除 TUIC 配置"
        ui_menu_item 0 "返回上一级"
        ui_blank
        ui_dim "主菜单：输入 0 退出脚本。子菜单：输入 0 返回上一级。"
        ui_dim "普通输入：输入 q 取消当前操作。"
        ui_blank
        ui_read_raw choice "请输入选项编号（0 返回）： " || return 1
        case "$choice" in
        1)
            ui_blank
            tuic_detect_config
            ui_pause
            ;;
        2)
            tuic_warn "菜单添加当前提供最小 insecure 向导；domain/file cert 建议使用 CLI。"
            tuic_reset_state
            ui_read_or_cancel tuic_port "请输入 TUIC UDP 监听端口（默认 10443，回车使用默认值，q 取消）： " || continue
            tuic_port=${tuic_port:-10443}
            tuic_add --port "$tuic_port" --uuid auto --password auto --insecure
            ui_pause
            ;;
        3)
            ui_blank
            config=$(tuic_detect_config | head -n 1)
            [[ $config ]] && tuic_url "$config" || ui_warn "未找到 TUIC 配置。"
            ui_pause
            ;;
        4)
            ui_warn "TUIC 菜单修改入口为最小占位，请使用 CLI: sing-box tuic change <config> ..."
            ui_pause
            ;;
        5)
            ui_blank
            tuic_audit
            ui_pause
            ;;
        6)
            ui_read_or_cancel config "请输入要删除的 TUIC 配置名（q 取消）： " || continue
            tuic_delete "$config"
            ui_pause
            ;;
        0)
            return 0
            ;;
        q | Q)
            ui_warn "子菜单请使用 0 返回上一级。"
            sleep 1
            ;;
        *)
            ui_error "无效选项，请重新输入。"
            sleep 1
            ;;
        esac
    done
}

# 中文注释：TUIC namespace 主分发入口。
tuic_main() {
    local subcommand=${1:-menu}

    case "$subcommand" in
    add)
        shift
        tuic_add "$@"
        ;;
    info)
        shift
        tuic_info "$@"
        ;;
    url)
        shift
        tuic_url "$@"
        ;;
    change)
        shift
        tuic_change "$@"
        ;;
    delete | del | rm)
        shift
        tuic_delete "$@"
        ;;
    migrate)
        shift
        tuic_migrate "$@"
        ;;
    audit)
        shift
        tuic_audit "$@"
        ;;
    menu)
        tuic_menu
        ;;
    -h | --help | help)
        ui_print "Usage: $is_core tuic <add|info|url|change|delete|migrate|audit|menu> [options]"
        ;;
    *)
        tuic_fail "无法识别 TUIC 子命令: $subcommand"
        return 1
        ;;
    esac
}
