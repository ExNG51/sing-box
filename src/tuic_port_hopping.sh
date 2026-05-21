#!/bin/bash

# 中文注释：TUIC Port-Hopping 系统对象管理模块；仅管理 TUIC UDP 跳跃端口实例。

: "${TUIC_HOP_BASE_DIR:=/etc/tuic-port-hopping}"
: "${TUIC_HOP_INSTANCE_DIR:=${TUIC_HOP_BASE_DIR}/instances}"
: "${TUIC_HOP_NFT_RULE_DIR:=/etc/nftables.d}"
: "${TUIC_HOP_APPLY_SCRIPT:=/usr/local/sbin/apply-tuic-port-hopping.sh}"
: "${TUIC_HOP_SYSTEMD_TEMPLATE:=/etc/systemd/system/tuic-port-hopping@.service}"
: "${TUIC_HOP_NFT_TABLE_PREFIX:=tuic_hopping_}"
: "${TUIC_HOP_DEFAULT_RANGE_SIZE:=100}"
: "${TUIC_HOP_DEFAULT_INTERVAL:=30}"

tuic_hop_reset_state() {
    unset TUIC_HOP_REAL_PORT TUIC_HOP_RANGE_START TUIC_HOP_RANGE_END TUIC_HOP_INTERVAL
    unset TUIC_HOP_RANGE_ARG TUIC_HOP_YES TUIC_HOP_CONFIRM_TOKEN TUIC_HOP_ALLOW_MISSING_LISTENER
}

tuic_hop_fail() {
    if type ui_error >/dev/null 2>&1; then
        ui_error "$*"
    else
        printf '[ERROR] %s\n' "$*" >&2
    fi
    return 1
}

tuic_hop_warn() {
    if type ui_warn >/dev/null 2>&1; then
        ui_warn "$*"
    else
        printf '[WARN] %s\n' "$*" >&2
    fi
}

tuic_hop_print() {
    if type ui_print >/dev/null 2>&1; then
        ui_print "$*"
    else
        printf '%s\n' "$*"
    fi
}

tuic_hop_blank() {
    if type ui_blank >/dev/null 2>&1; then
        ui_blank
    else
        printf '\n'
    fi
}

tuic_hop_kv() {
    if type ui_kv >/dev/null 2>&1; then
        ui_kv "$1" "${2:-}"
    else
        printf '%-18s%s\n' "$1" "${2:-}"
    fi
}

tuic_hop_command_exists() {
    type -P "$1" >/dev/null 2>&1
}

tuic_hop_require_root_for_write() {
    [[ ${TUIC_HOP_ALLOW_NON_ROOT:-} ]] && return 0
    case "${TUIC_HOP_BASE_DIR}:${TUIC_HOP_NFT_RULE_DIR}:${TUIC_HOP_APPLY_SCRIPT}:${TUIC_HOP_SYSTEMD_TEMPLATE}" in
    /etc/*:* | *:/etc/*:* | *:/usr/local/*:* | *:/etc/*)
        [[ ${EUID:-$(id -u)} -eq 0 ]] || {
            tuic_hop_fail "TUIC Port-Hopping 写入系统路径需要 root 权限。"
            return 1
        }
        ;;
    esac
}

tuic_hop_validate_port() {
    local port=${1:-}
    [[ $port =~ ^[1-9][0-9]*$ ]] && [[ $port -le 65535 ]]
}

tuic_hop_is_port_in_range() {
    local port=$1 start=$2 end=$3
    [[ $port -ge $start && $port -le $end ]]
}

tuic_hop_ranges_overlap() {
    local a_start=$1 a_end=$2 b_start=$3 b_end=$4
    [[ $a_start -le $b_end && $b_start -le $a_end ]]
}

tuic_hop_validate_range() {
    local real_port=$1 start_port=$2 end_port=$3

    tuic_hop_validate_port "$real_port" || return 1
    tuic_hop_validate_port "$start_port" || return 1
    tuic_hop_validate_port "$end_port" || return 1
    [[ $start_port -lt $end_port ]] || return 1
    tuic_hop_is_port_in_range "$real_port" "$start_port" "$end_port" && return 1
    return 0
}

tuic_hop_parse_range_arg() {
    local real_port=$1 range=$2
    local start_port end_port

    [[ $range =~ ^[0-9]+-[0-9]+$ ]] || return 1
    start_port=${range%-*}
    end_port=${range#*-}
    tuic_hop_validate_range "$real_port" "$start_port" "$end_port" || return 1
    printf '%s %s\n' "$start_port" "$end_port"
}

tuic_hop_get_config_file() {
    printf '%s/%s.env\n' "$TUIC_HOP_INSTANCE_DIR" "$1"
}

tuic_hop_get_nft_table_name() {
    printf '%s%s\n' "$TUIC_HOP_NFT_TABLE_PREFIX" "$1"
}

tuic_hop_get_nft_rule_file() {
    printf '%s/tuic-port-hopping-%s.nft\n' "$TUIC_HOP_NFT_RULE_DIR" "$1"
}

tuic_hop_get_service_name() {
    printf 'tuic-port-hopping@%s.service\n' "$1"
}

tuic_hop_read_env_value() {
    local file_path=$1 key_name=$2
    local line value

    [[ $key_name =~ ^[A-Z0-9_]+$ ]] || return 1
    [[ -f $file_path ]] || return 1
    line=$(grep -E "^${key_name}=" "$file_path" 2>/dev/null | head -n 1) || return 1
    [[ $line ]] || return 1
    value=${line#*=}
    value=${value%\"}
    value=${value#\"}
    printf '%s\n' "$value"
}

tuic_hop_validate_env_file() {
    local file_path=$1 real_port range_start range_end interval table rule_file

    [[ -f $file_path ]] || return 1
    real_port=$(tuic_hop_read_env_value "$file_path" REAL_PORT) || return 1
    range_start=$(tuic_hop_read_env_value "$file_path" RANGE_START) || return 1
    range_end=$(tuic_hop_read_env_value "$file_path" RANGE_END) || return 1
    interval=$(tuic_hop_read_env_value "$file_path" HOP_INTERVAL 2>/dev/null || printf '%s\n' "$TUIC_HOP_DEFAULT_INTERVAL")
    table=$(tuic_hop_read_env_value "$file_path" NFT_TABLE_NAME) || return 1
    rule_file=$(tuic_hop_read_env_value "$file_path" NFT_RULE_FILE) || return 1

    tuic_hop_validate_range "$real_port" "$range_start" "$range_end" || return 1
    [[ $interval =~ ^[1-9][0-9]*$ ]] || return 1
    [[ $table == "$(tuic_hop_get_nft_table_name "$real_port")" ]] || return 1
    [[ $rule_file == "$(tuic_hop_get_nft_rule_file "$real_port")" ]] || return 1
}

tuic_hop_list_instances() {
    local file_path base

    [[ -d $TUIC_HOP_INSTANCE_DIR ]] || return 0
    for file_path in "$TUIC_HOP_INSTANCE_DIR"/*.env; do
        [[ -e $file_path ]] || continue
        base=$(basename "$file_path" .env)
        tuic_hop_validate_port "$base" && printf '%s\n' "$base"
    done | sort -n
}

tuic_hop_has_instance() {
    local port=$1
    tuic_hop_validate_port "$port" || return 1
    tuic_hop_validate_env_file "$(tuic_hop_get_config_file "$port")"
}

tuic_hop_count_instances() {
    tuic_hop_list_instances | sed '/^$/d' | wc -l | tr -d ' '
}

tuic_hop_systemd_is_active() {
    local service=$1
    [[ ${TUIC_HOP_SKIP_SYSTEMD:-} ]] && return 1
    tuic_hop_command_exists systemctl || return 1
    systemctl is-active --quiet "$service" 2>/dev/null
}

tuic_hop_systemd_is_enabled() {
    local service=$1
    [[ ${TUIC_HOP_SKIP_SYSTEMD:-} ]] && return 1
    tuic_hop_command_exists systemctl || return 1
    systemctl is-enabled --quiet "$service" 2>/dev/null
}

tuic_hop_count_active_instances() {
    local port count=0

    while IFS= read -r port; do
        [[ $port ]] || continue
        tuic_hop_systemd_is_active "$(tuic_hop_get_service_name "$port")" && count=$((count + 1))
    done < <(tuic_hop_list_instances)
    printf '%s\n' "$count"
}

tuic_hop_detect_instance_for_port() {
    local port=$1
    tuic_hop_has_instance "$port" && printf '%s\n' "$port"
}

tuic_hop_range_conflicts_quiet() {
    local real_port=$1 start_port=$2 end_port=$3
    local cfg other_port other_start other_end

    tuic_hop_validate_range "$real_port" "$start_port" "$end_port" || return 0
    [[ -d $TUIC_HOP_INSTANCE_DIR ]] || return 1
    for cfg in "$TUIC_HOP_INSTANCE_DIR"/*.env; do
        [[ -e $cfg ]] || continue
        other_port=$(tuic_hop_read_env_value "$cfg" REAL_PORT 2>/dev/null || true)
        other_start=$(tuic_hop_read_env_value "$cfg" RANGE_START 2>/dev/null || true)
        other_end=$(tuic_hop_read_env_value "$cfg" RANGE_END 2>/dev/null || true)
        tuic_hop_validate_port "$other_port" || continue
        tuic_hop_validate_port "$other_start" || continue
        tuic_hop_validate_port "$other_end" || continue
        [[ $other_port == "$real_port" ]] && continue
        tuic_hop_ranges_overlap "$start_port" "$end_port" "$other_start" "$other_end" && return 0
        tuic_hop_is_port_in_range "$other_port" "$start_port" "$end_port" && return 0
        tuic_hop_is_port_in_range "$real_port" "$other_start" "$other_end" && return 0
    done
    return 1
}

tuic_hop_calculate_auto_range() {
    local real_port=$1 range_size=${2:-$TUIC_HOP_DEFAULT_RANGE_SIZE}
    local start_port end_port attempts max_start

    tuic_hop_validate_port "$real_port" || return 1
    [[ $range_size =~ ^[1-9][0-9]*$ && $range_size -le 1000 ]] || range_size=$TUIC_HOP_DEFAULT_RANGE_SIZE

    if [[ $real_port -le $((65535 - 10000)) ]]; then
        start_port=$((real_port + 10000))
    else
        start_port=$((real_port - 10000))
    fi
    [[ $start_port -lt 1024 ]] && start_port=1024
    max_start=$((65535 - range_size + 1))
    [[ $start_port -gt $max_start ]] && start_port=$max_start

    for ((attempts = 0; attempts < 700; attempts++)); do
        end_port=$((start_port + range_size - 1))
        if tuic_hop_validate_range "$real_port" "$start_port" "$end_port" && ! tuic_hop_range_conflicts_quiet "$real_port" "$start_port" "$end_port"; then
            printf '%s-%s\n' "$start_port" "$end_port"
            return 0
        fi
        start_port=$((start_port + range_size))
        [[ $start_port -gt $max_start ]] && start_port=1024
    done
    return 1
}

tuic_hop_check_instance_port_conflict() {
    local real_port=$1 start_port=$2 end_port=$3
    local cfg other_port other_start other_end

    tuic_hop_validate_range "$real_port" "$start_port" "$end_port" || {
        tuic_hop_fail "TUIC Port-Hopping 范围无效或包含真实 UDP 端口: ${start_port}-${end_port}/udp"
        return 1
    }
    [[ -d $TUIC_HOP_INSTANCE_DIR ]] || return 0
    for cfg in "$TUIC_HOP_INSTANCE_DIR"/*.env; do
        [[ -e $cfg ]] || continue
        other_port=$(tuic_hop_read_env_value "$cfg" REAL_PORT 2>/dev/null || true)
        other_start=$(tuic_hop_read_env_value "$cfg" RANGE_START 2>/dev/null || true)
        other_end=$(tuic_hop_read_env_value "$cfg" RANGE_END 2>/dev/null || true)
        tuic_hop_validate_port "$other_port" || continue
        tuic_hop_validate_port "$other_start" || continue
        tuic_hop_validate_port "$other_end" || continue
        [[ $other_port == "$real_port" ]] && continue
        if tuic_hop_ranges_overlap "$start_port" "$end_port" "$other_start" "$other_end"; then
            tuic_hop_fail "跳跃 UDP 范围与已有实例 $other_port 冲突: ${other_start}-${other_end}/udp"
            return 1
        fi
        if tuic_hop_is_port_in_range "$other_port" "$start_port" "$end_port"; then
            tuic_hop_fail "跳跃 UDP 范围包含其他实例真实端口: ${other_port}/udp"
            return 1
        fi
        if tuic_hop_is_port_in_range "$real_port" "$other_start" "$other_end"; then
            tuic_hop_fail "真实 UDP 端口 $real_port 落入已有实例 $other_port 的跳跃范围。"
            return 1
        fi
    done
    return 0
}

tuic_hop_is_udp_port_listening() {
    local port=$1

    tuic_hop_validate_port "$port" || return 1
    tuic_hop_command_exists ss || return 2
    ss -H -lunp 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"
}

tuic_hop_check_tuic_listener() {
    local real_port=$1 allow_missing=${2:-}

    tuic_hop_is_udp_port_listening "$real_port" && return 0
    [[ $allow_missing ]] && {
        tuic_hop_warn "未检测到 TUIC UDP ${real_port} 监听；已按显式参数继续。"
        return 0
    }
    tuic_hop_fail "未检测到 TUIC UDP ${real_port} 正在监听；可使用 --allow-missing-listener 或 --yes 显式继续。"
    return 1
}

tuic_hop_check_range_listener_conflict() {
    local start_port=$1 end_port=$2
    local used_ports used_port found=0

    tuic_hop_command_exists ss || return 0
    used_ports=$(ss -H -lunp 2>/dev/null | grep -Eo ':[0-9]+' | tr -d ':' | sort -n | uniq || true)
    for used_port in $used_ports; do
        tuic_hop_validate_port "$used_port" || continue
        if tuic_hop_is_port_in_range "$used_port" "$start_port" "$end_port"; then
            tuic_hop_warn "跳跃范围内检测到已监听 UDP 端口: ${used_port}/udp"
            found=1
        fi
    done
    [[ $found -eq 0 ]]
}

tuic_hop_render_instance_env() {
    local real_port=$1 range_start=$2 range_end=$3 interval=${4:-$TUIC_HOP_DEFAULT_INTERVAL}
    local table rule_file updated

    tuic_hop_validate_range "$real_port" "$range_start" "$range_end" || return 1
    [[ $interval =~ ^[1-9][0-9]*$ ]] || interval=$TUIC_HOP_DEFAULT_INTERVAL
    table=$(tuic_hop_get_nft_table_name "$real_port")
    rule_file=$(tuic_hop_get_nft_rule_file "$real_port")
    updated=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    printf 'REAL_PORT="%s"\n' "$real_port"
    printf 'RANGE_START="%s"\n' "$range_start"
    printf 'RANGE_END="%s"\n' "$range_end"
    printf 'HOP_INTERVAL="%s"\n' "$interval"
    printf 'NFT_TABLE_NAME="%s"\n' "$table"
    printf 'NFT_RULE_FILE="%s"\n' "$rule_file"
    printf 'UPDATED_AT="%s"\n' "$updated"
}

tuic_hop_render_nft_rule() {
    local real_port=$1 range_start=$2 range_end=$3
    local table

    tuic_hop_validate_range "$real_port" "$range_start" "$range_end" || return 1
    table=$(tuic_hop_get_nft_table_name "$real_port")
    cat <<EOF_NFT
table inet ${table} {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

        udp dport ${range_start}-${range_end} redirect to :${real_port}
    }
}
EOF_NFT
}

tuic_hop_render_apply_script() {
    cat <<EOF_APPLY
#!/bin/sh
set -eu

port="\${1:-}"
if [ -z "\$port" ]; then
    echo "[ERROR] missing TUIC Port-Hopping instance port." >&2
    exit 1
fi
case "\$port" in
    *[!0-9]*|"") echo "[ERROR] invalid instance port: \$port" >&2; exit 1 ;;
esac
if [ "\$port" -lt 1 ] || [ "\$port" -gt 65535 ]; then
    echo "[ERROR] invalid instance port: \$port" >&2
    exit 1
fi

config_file="${TUIC_HOP_INSTANCE_DIR}/\${port}.env"
if [ ! -f "\$config_file" ]; then
    echo "[ERROR] missing instance env: \$config_file" >&2
    exit 1
fi

read_value() {
    key="\$1"
    grep -E "^\${key}=" "\$config_file" 2>/dev/null | head -n 1 | cut -d '=' -f 2- | sed 's/^"//; s/"$//'
}

real_port="\$(read_value REAL_PORT)"
range_start="\$(read_value RANGE_START)"
range_end="\$(read_value RANGE_END)"
nft_table_name="\$(read_value NFT_TABLE_NAME)"
nft_rule_file="\$(read_value NFT_RULE_FILE)"

case "\$real_port:\$range_start:\$range_end" in
    *[!0-9:]*|:*|*:) echo "[ERROR] invalid numeric fields in \$config_file" >&2; exit 1 ;;
esac
if [ "\$real_port" != "\$port" ]; then
    echo "[ERROR] REAL_PORT does not match instance name: \$config_file" >&2
    exit 1
fi
case "\$nft_table_name" in
    ${TUIC_HOP_NFT_TABLE_PREFIX}[0-9]*) ;;
    *) echo "[ERROR] invalid nft table name: \$nft_table_name" >&2; exit 1 ;;
esac
case "\$nft_rule_file" in
    ${TUIC_HOP_NFT_RULE_DIR}/tuic-port-hopping-[0-9]*.nft) ;;
    *) echo "[ERROR] invalid nft rule file: \$nft_rule_file" >&2; exit 1 ;;
esac

if nft list table inet "\$nft_table_name" >/dev/null 2>&1; then
    nft delete table inet "\$nft_table_name"
fi
nft -f "\$nft_rule_file"
EOF_APPLY
}

tuic_hop_render_systemd_template() {
    cat <<EOF_SYSTEMD
[Unit]
Description=TUIC Port-Hopping nftables instance %i
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${TUIC_HOP_APPLY_SCRIPT} %i

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
}

tuic_hop_safe_write_file() {
    local path=$1 content=$2
    type safe_write_file >/dev/null 2>&1 || {
        tuic_hop_fail "缺少 safe_write_file，拒绝写入: $path"
        return 1
    }
    safe_write_file "$path" "$content"
}

tuic_hop_safe_ensure_dir() {
    local path=$1
    type safe_ensure_dir >/dev/null 2>&1 || {
        tuic_hop_fail "缺少 safe_ensure_dir，拒绝创建目录: $path"
        return 1
    }
    safe_ensure_dir "$path"
}

tuic_hop_safe_remove_path() {
    type safe_remove_path >/dev/null 2>&1 || {
        tuic_hop_fail "缺少 safe_remove_path，拒绝删除。"
        return 1
    }
    safe_remove_path "$@"
}

# 中文注释：预校验即将删除的 Port-Hopping 文件是否属于脚本管理范围。
tuic_hop_precheck_remove_paths() {
    local path

    type assert_safe_remove_path >/dev/null 2>&1 || {
        tuic_hop_fail "缺少 assert_safe_remove_path，拒绝删除 TUIC Port-Hopping 文件。"
        return 1
    }
    for path in "$@"; do
        assert_safe_remove_path "$path" || return 1
    done
}

tuic_hop_write_common_files() {
    local apply_content systemd_content

    tuic_hop_require_root_for_write || return 1
    apply_content=$(tuic_hop_render_apply_script) || return 1
    systemd_content=$(tuic_hop_render_systemd_template) || return 1

    tuic_hop_safe_ensure_dir "$TUIC_HOP_BASE_DIR" || return 1
    tuic_hop_safe_ensure_dir "$TUIC_HOP_INSTANCE_DIR" || return 1
    tuic_hop_safe_ensure_dir "$TUIC_HOP_NFT_RULE_DIR" || return 1
    tuic_hop_safe_ensure_dir "$(dirname "$TUIC_HOP_APPLY_SCRIPT")" || return 1
    tuic_hop_safe_ensure_dir "$(dirname "$TUIC_HOP_SYSTEMD_TEMPLATE")" || return 1
    tuic_hop_safe_write_file "$TUIC_HOP_APPLY_SCRIPT" "$apply_content" || return 1
    type safe_chmod_path >/dev/null 2>&1 || {
        tuic_hop_fail "缺少 safe_chmod_path，拒绝 chmod: $TUIC_HOP_APPLY_SCRIPT"
        return 1
    }
    safe_chmod_path 755 "$TUIC_HOP_APPLY_SCRIPT" || return 1
    tuic_hop_safe_write_file "$TUIC_HOP_SYSTEMD_TEMPLATE" "$systemd_content" || return 1
}

tuic_hop_check_nft_rule_syntax() {
    local file_path=$1

    [[ ${TUIC_HOP_SKIP_NFT:-} ]] && return 0
    tuic_hop_command_exists nft || {
        tuic_hop_warn "未检测到 nft 命令，跳过 nftables 语法检查。"
        return 0
    }
    nft -c -f "$file_path" >/dev/null 2>&1
}

tuic_hop_apply_instance() {
    local real_port=$1

    [[ ${TUIC_HOP_SKIP_NFT:-} ]] && return 0
    tuic_hop_command_exists nft || {
        tuic_hop_warn "未检测到 nft 命令，跳过 nftables 应用。"
        return 0
    }
    "$TUIC_HOP_APPLY_SCRIPT" "$real_port"
}

tuic_hop_enable_instance() {
    local real_port=$1 service

    [[ ${TUIC_HOP_SKIP_SYSTEMD:-} ]] && return 0
    tuic_hop_command_exists systemctl || {
        tuic_hop_warn "未检测到 systemctl，跳过 systemd enable/start。"
        return 0
    }
    service=$(tuic_hop_get_service_name "$real_port")
    systemctl daemon-reload || return 1
    systemctl enable --now "$service" || return 1
}

tuic_hop_configure_ufw_rules() {
    local real_port=$1 range_start=$2 range_end=$3
    local status

    [[ ${TUIC_HOP_SKIP_UFW:-} ]] && return 0
    tuic_hop_command_exists ufw || {
        tuic_hop_warn "未检测到 UFW，跳过 UFW 放行。"
        return 0
    }
    status=$(ufw status 2>/dev/null || true)
    if ! grep -qi '^Status:[[:space:]]*active' <<<"$status"; then
        tuic_hop_warn "UFW 未处于 active，未强制启用；请确认 UDP ${real_port} 与 ${range_start}-${range_end} 已放行。"
        return 0
    fi
    ufw allow "${real_port}/udp" >/dev/null || return 1
    ufw allow "${range_start}:${range_end}/udp" >/dev/null || return 1
}

tuic_hop_create_or_update_instance() {
    local real_port=$1 range_arg=${2:-auto} interval=${3:-$TUIC_HOP_DEFAULT_INTERVAL} allow_missing_listener=${4:-}
    local preflight range_start range_end env_file nft_file env_content nft_content should_finalize=false

    preflight=$(tuic_hop_preflight_create_or_update_instance "$real_port" "$range_arg" "$interval" "$allow_missing_listener") || return 1
    read -r range_start range_end <<<"$preflight"

    env_file=$(tuic_hop_get_config_file "$real_port")
    nft_file=$(tuic_hop_get_nft_rule_file "$real_port")
    env_content=$(tuic_hop_render_instance_env "$real_port" "$range_start" "$range_end" "$interval") || return 1
    nft_content=$(tuic_hop_render_nft_rule "$real_port" "$range_start" "$range_end") || return 1

    begin_backup_transaction_if_needed tuic-hop-upsert && should_finalize=true
    {
        tuic_hop_write_common_files &&
            tuic_hop_safe_write_file "$env_file" "$env_content" &&
            tuic_hop_safe_write_file "$nft_file" "$nft_content" &&
            tuic_hop_check_nft_rule_syntax "$nft_file" &&
            tuic_hop_apply_instance "$real_port" &&
            tuic_hop_enable_instance "$real_port" &&
            tuic_hop_configure_ufw_rules "$real_port" "$range_start" "$range_end"
    } || {
        type rollback_latest_backup >/dev/null 2>&1 && rollback_latest_backup --yes >/dev/null 2>&1 || true
        tuic_hop_warn "TUIC Port-Hopping 写入失败，已尝试回滚。"
        tuic_hop_report_residuals "$real_port"
        return 1
    }
    [[ $should_finalize == true || ${IS_BACKUP_ACTIVE:-} == true ]] && finalize_backup_transaction

    tuic_hop_blank
    tuic_hop_kv "真实端口" "${real_port}/udp"
    tuic_hop_kv "跳跃范围" "${range_start}-${range_end}/udp"
    tuic_hop_kv "systemd" "$(tuic_hop_get_service_name "$real_port")"
    tuic_hop_warn "请确认云安全组已放行 UDP ${real_port} 与 ${range_start}-${range_end}。"
    tuic_hop_show_client_hint "$real_port"
}

# 中文注释：只执行创建/更新 Port-Hopping 前的输入与冲突预检，不写系统对象。
tuic_hop_preflight_create_or_update_instance() {
    local real_port=$1 range_arg=${2:-auto} interval=${3:-$TUIC_HOP_DEFAULT_INTERVAL} allow_missing_listener=${4:-}
    local range range_start range_end

    tuic_hop_validate_port "$real_port" || {
        tuic_hop_fail "TUIC Port-Hopping 真实 UDP 端口无效: $real_port"
        return 1
    }
    [[ $interval =~ ^[1-9][0-9]*$ ]] || {
        tuic_hop_fail "TUIC Port-Hopping interval 无效: $interval"
        return 1
    }
    if [[ $range_arg == auto || ! $range_arg ]]; then
        range=$(tuic_hop_calculate_auto_range "$real_port") || {
            tuic_hop_fail "无法自动计算可用 TUIC Port-Hopping UDP 范围。"
            return 1
        }
        range_start=${range%-*}
        range_end=${range#*-}
    else
        read -r range_start range_end < <(tuic_hop_parse_range_arg "$real_port" "$range_arg") || {
            tuic_hop_fail "TUIC Port-Hopping UDP 范围无效: $range_arg"
            return 1
        }
    fi
    tuic_hop_check_instance_port_conflict "$real_port" "$range_start" "$range_end" || return 1
    tuic_hop_check_tuic_listener "$real_port" "$allow_missing_listener" || return 1
    tuic_hop_check_range_listener_conflict "$range_start" "$range_end" || {
        [[ ${TUIC_HOP_ALLOW_RANGE_LISTENER:-} ]] || return 1
    }

    printf '%s %s\n' "$range_start" "$range_end"
}

tuic_hop_nft_table_exists() {
    local table=$1
    [[ ${TUIC_HOP_SKIP_NFT:-} ]] && return 1
    tuic_hop_command_exists nft || return 1
    nft list table inet "$table" >/dev/null 2>&1
}

tuic_hop_ufw_status() {
    [[ ${TUIC_HOP_SKIP_UFW:-} ]] && {
        printf 'skipped\n'
        return 0
    }
    tuic_hop_command_exists ufw || {
        printf 'not installed\n'
        return 0
    }
    if ufw status 2>/dev/null | grep -qi '^Status:[[:space:]]*active'; then
        printf 'active\n'
    else
        printf 'inactive\n'
    fi
}

tuic_hop_status_instance() {
    local real_port=$1 cfg range_start range_end interval table nft_file service updated systemd_state nft_state rule_state ufw_state

    tuic_hop_validate_port "$real_port" || return 1
    cfg=$(tuic_hop_get_config_file "$real_port")
    tuic_hop_validate_env_file "$cfg" || {
        tuic_hop_fail "未找到有效 TUIC Port-Hopping 实例: ${real_port}/udp"
        return 1
    }
    range_start=$(tuic_hop_read_env_value "$cfg" RANGE_START)
    range_end=$(tuic_hop_read_env_value "$cfg" RANGE_END)
    interval=$(tuic_hop_read_env_value "$cfg" HOP_INTERVAL 2>/dev/null || printf '%s\n' "$TUIC_HOP_DEFAULT_INTERVAL")
    table=$(tuic_hop_read_env_value "$cfg" NFT_TABLE_NAME)
    nft_file=$(tuic_hop_read_env_value "$cfg" NFT_RULE_FILE)
    updated=$(tuic_hop_read_env_value "$cfg" UPDATED_AT 2>/dev/null || printf '%s\n' "-")
    service=$(tuic_hop_get_service_name "$real_port")
    systemd_state=inactive
    tuic_hop_systemd_is_active "$service" && systemd_state=active
    [[ $systemd_state == inactive ]] && tuic_hop_systemd_is_enabled "$service" && systemd_state=enabled
    nft_state=missing
    tuic_hop_nft_table_exists "$table" && nft_state=exists
    rule_state=missing
    [[ -f $nft_file ]] && rule_state=exists
    ufw_state=$(tuic_hop_ufw_status)

    tuic_hop_kv "REAL_PORT" "${real_port}/udp"
    tuic_hop_kv "RANGE" "${range_start}-${range_end}/udp"
    tuic_hop_kv "HOP_INTERVAL" "${interval}s"
    tuic_hop_kv "systemd service" "$service"
    tuic_hop_kv "systemd state" "$systemd_state"
    tuic_hop_kv "nft table" "inet $table ($nft_state)"
    tuic_hop_kv "rule file" "$nft_file ($rule_state)"
    tuic_hop_kv "UFW" "$ufw_state"
    tuic_hop_kv "UPDATED_AT" "$updated"
}

tuic_hop_validate_instance() {
    local real_port=$1 cfg range_start range_end table nft_file service failed=0

    cfg=$(tuic_hop_get_config_file "$real_port")
    tuic_hop_validate_env_file "$cfg" || {
        tuic_hop_fail "实例 env 无效或缺失: $cfg"
        return 1
    }
    range_start=$(tuic_hop_read_env_value "$cfg" RANGE_START)
    range_end=$(tuic_hop_read_env_value "$cfg" RANGE_END)
    table=$(tuic_hop_read_env_value "$cfg" NFT_TABLE_NAME)
    nft_file=$(tuic_hop_read_env_value "$cfg" NFT_RULE_FILE)
    service=$(tuic_hop_get_service_name "$real_port")

    [[ -f $nft_file ]] || {
        tuic_hop_warn "nft rule file 缺失: $nft_file"
        failed=1
    }
    tuic_hop_nft_table_exists "$table" || {
        tuic_hop_warn "nft table 不存在: inet $table"
        failed=1
    }
    tuic_hop_systemd_is_active "$service" || {
        tuic_hop_warn "systemd service 非 active: $service"
        failed=1
    }
    tuic_hop_is_udp_port_listening "$real_port" || {
        tuic_hop_warn "未检测到真实 TUIC UDP ${real_port} 监听。"
        failed=1
    }

    tuic_hop_status_instance "$real_port"
    tuic_hop_warn "请确认云安全组放行 UDP ${real_port} 与 ${range_start}-${range_end}。"
    [[ $failed -eq 0 ]]
}

# 中文注释：迁移后的运行态不可测时，至少验证新实例文件已完整写入。
tuic_hop_validate_migrated_instance() {
    local real_port=$1 allow_missing_listener=${2:-}
    local cfg table nft_file service failed=0 runtime_skipped=false

    cfg=$(tuic_hop_get_config_file "$real_port")
    tuic_hop_validate_env_file "$cfg" || return 1
    table=$(tuic_hop_read_env_value "$cfg" NFT_TABLE_NAME) || return 1
    nft_file=$(tuic_hop_read_env_value "$cfg" NFT_RULE_FILE) || return 1
    service=$(tuic_hop_get_service_name "$real_port")

    [[ -f $nft_file ]] || {
        tuic_hop_warn "nft rule file 缺失: $nft_file"
        failed=1
    }
    if [[ ${TUIC_HOP_SKIP_NFT:-} ]] || ! tuic_hop_command_exists nft; then
        runtime_skipped=true
    else
        tuic_hop_nft_table_exists "$table" || {
            tuic_hop_warn "nft table 不存在: inet $table"
            failed=1
        }
    fi
    if [[ ${TUIC_HOP_SKIP_SYSTEMD:-} ]] || ! tuic_hop_command_exists systemctl; then
        runtime_skipped=true
    else
        tuic_hop_systemd_is_active "$service" || {
            tuic_hop_warn "systemd service 非 active: $service"
            failed=1
        }
    fi
    tuic_hop_is_udp_port_listening "$real_port" || {
        if [[ $allow_missing_listener ]]; then
            tuic_hop_warn "未检测到真实 TUIC UDP ${real_port} 监听；已按显式参数继续。"
        else
            tuic_hop_warn "未检测到真实 TUIC UDP ${real_port} 监听。"
            failed=1
        fi
    }

    tuic_hop_status_instance "$real_port" || true
    [[ $runtime_skipped == true && $failed -eq 0 ]] && tuic_hop_warn "运行态验证不可用，已完成 TUIC Port-Hopping 文件级验证。"
    [[ $failed -eq 0 ]]
}

# 中文注释：迁移 Port-Hopping 实例；优先创建新实例并验证，通过后再删除旧实例。
tuic_hop_migrate_instance() {
    local old_port=$1 new_port=$2 range_arg=${3:-auto} interval=${4:-$TUIC_HOP_DEFAULT_INTERVAL} allow_missing_listener=${5:-}
    local old_cfg old_start old_end new_range_arg candidate_start candidate_end preflight

    tuic_hop_validate_port "$old_port" || {
        tuic_hop_fail "旧 TUIC Port-Hopping 真实 UDP 端口无效: $old_port"
        return 1
    }
    tuic_hop_validate_port "$new_port" || {
        tuic_hop_fail "新 TUIC Port-Hopping 真实 UDP 端口无效: $new_port"
        return 1
    }
    [[ $old_port != "$new_port" ]] || return 0
    [[ $interval =~ ^[1-9][0-9]*$ ]] || interval=$TUIC_HOP_DEFAULT_INTERVAL

    tuic_hop_has_instance "$old_port" || {
        tuic_hop_fail "未找到旧 TUIC Port-Hopping 实例: ${old_port}/udp"
        return 1
    }
    tuic_hop_has_instance "$new_port" && {
        tuic_hop_fail "新真实端口已存在 TUIC Port-Hopping 实例: ${new_port}/udp"
        return 1
    }

    old_cfg=$(tuic_hop_get_config_file "$old_port")
    old_start=$(tuic_hop_read_env_value "$old_cfg" RANGE_START) || return 1
    old_end=$(tuic_hop_read_env_value "$old_cfg" RANGE_END) || return 1
    new_range_arg=${range_arg:-auto}
    if [[ $new_range_arg != auto && $new_range_arg =~ ^[0-9]+-[0-9]+$ ]]; then
        candidate_start=${new_range_arg%-*}
        candidate_end=${new_range_arg#*-}
        if tuic_hop_validate_port "$candidate_start" &&
            tuic_hop_validate_port "$candidate_end" &&
            { tuic_hop_ranges_overlap "$candidate_start" "$candidate_end" "$old_start" "$old_end" ||
                tuic_hop_is_port_in_range "$old_port" "$candidate_start" "$candidate_end" ||
                tuic_hop_is_port_in_range "$new_port" "$old_start" "$old_end"; }; then
            tuic_hop_warn "迁移时请求范围与旧实例冲突，已改用 auto 范围。"
            new_range_arg=auto
        fi
    fi

    preflight=$(tuic_hop_preflight_create_or_update_instance "$new_port" "$new_range_arg" "$interval" "$allow_missing_listener") || return 1
    read -r candidate_start candidate_end <<<"$preflight"
    tuic_hop_create_or_update_instance "$new_port" "${candidate_start}-${candidate_end}" "$interval" "$allow_missing_listener" || {
        tuic_hop_warn "新 TUIC Port-Hopping 实例创建失败，旧实例已保留。"
        tuic_hop_report_residuals "$old_port"
        return 1
    }
    tuic_hop_validate_migrated_instance "$new_port" "$allow_missing_listener" || {
        tuic_hop_warn "新 TUIC Port-Hopping 实例验证失败，旧实例已保留。"
        tuic_hop_report_residuals "$old_port"
        return 1
    }
    tuic_hop_delete_instance "$old_port" --yes || {
        tuic_hop_warn "旧 TUIC Port-Hopping 实例删除失败，请按残留报告人工确认。"
        tuic_hop_report_residuals "$old_port"
        return 1
    }
}

tuic_hop_delete_instance() {
    local real_port=$1 service cfg nft_file table range_start range_end should_finalize=false
    local delete_yes= delete_confirm= state_mutated=false
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --yes)
            delete_yes=1
            shift
            ;;
        --confirm)
            [[ ${2:-} ]] || return 1
            delete_confirm=$2
            shift 2
            ;;
        *)
            tuic_hop_fail "无法识别 TUIC Port-Hopping delete 参数: $1"
            return 1
            ;;
        esac
    done

    tuic_hop_validate_port "$real_port" || return 1
    cfg=$(tuic_hop_get_config_file "$real_port")
    tuic_hop_validate_env_file "$cfg" || {
        tuic_hop_fail "未找到有效 TUIC Port-Hopping 实例: ${real_port}/udp"
        return 1
    }
    [[ $delete_yes || $delete_confirm == DELETE-HOP ]] || {
        tuic_hop_fail "删除 TUIC Port-Hopping 实例需要 --yes 或 --confirm DELETE-HOP。"
        return 1
    }

    nft_file=$(tuic_hop_read_env_value "$cfg" NFT_RULE_FILE)
    table=$(tuic_hop_read_env_value "$cfg" NFT_TABLE_NAME)
    range_start=$(tuic_hop_read_env_value "$cfg" RANGE_START)
    range_end=$(tuic_hop_read_env_value "$cfg" RANGE_END)
    service=$(tuic_hop_get_service_name "$real_port")

    tuic_hop_precheck_remove_paths "$cfg" "$nft_file" || {
        tuic_hop_report_residuals "$real_port"
        return 1
    }
    if begin_backup_transaction_if_needed tuic-hop-delete; then
        should_finalize=true
    elif [[ ${IS_BACKUP_ACTIVE:-} != true ]]; then
        return 1
    fi
    if type backup_path_before_write >/dev/null 2>&1; then
        backup_path_before_write "$cfg" || {
            type rollback_latest_backup >/dev/null 2>&1 && rollback_latest_backup --yes >/dev/null 2>&1 || true
            tuic_hop_report_residuals "$real_port"
            return 1
        }
        backup_path_before_write "$nft_file" || {
            type rollback_latest_backup >/dev/null 2>&1 && rollback_latest_backup --yes >/dev/null 2>&1 || true
            tuic_hop_report_residuals "$real_port"
            return 1
        }
    fi
    if [[ ! ${TUIC_HOP_SKIP_SYSTEMD:-} ]] && tuic_hop_command_exists systemctl; then
        if systemctl disable --now "$service" >/dev/null 2>&1; then
            state_mutated=true
        else
            type rollback_latest_backup >/dev/null 2>&1 && rollback_latest_backup --yes >/dev/null 2>&1 || true
            tuic_hop_warn "停止/禁用 TUIC Port-Hopping systemd 实例失败，已中止删除。"
            tuic_hop_report_residuals "$real_port"
            return 1
        fi
    fi
    if [[ ! ${TUIC_HOP_SKIP_NFT:-} ]] && tuic_hop_command_exists nft && nft list table inet "$table" >/dev/null 2>&1; then
        if nft delete table inet "$table"; then
            state_mutated=true
        else
            type rollback_latest_backup >/dev/null 2>&1 && rollback_latest_backup --yes >/dev/null 2>&1 || true
            tuic_hop_warn "删除 TUIC Port-Hopping nft table 失败，已中止删除。"
            tuic_hop_report_residuals "$real_port"
            return 1
        fi
    fi
    tuic_hop_safe_remove_path "$cfg" "$nft_file" || {
        type rollback_latest_backup >/dev/null 2>&1 && rollback_latest_backup --yes >/dev/null 2>&1 || true
        tuic_hop_warn "TUIC Port-Hopping 删除失败，已尝试回滚。"
        [[ $state_mutated == true ]] && tuic_hop_warn "systemd/nftables 运行态可能已变化，不保证已恢复。"
        tuic_hop_report_residuals "$real_port"
        return 1
    }
    [[ $should_finalize == true || ${IS_BACKUP_ACTIVE:-} == true ]] && finalize_backup_transaction

    tuic_hop_kv "已删除实例" "${real_port}/udp"
    tuic_hop_warn "未自动删除 UFW 规则；请人工确认 ${real_port}/udp 与 ${range_start}:${range_end}/udp 是否仍需保留。"
    tuic_hop_report_residuals "$real_port" || true
}

tuic_hop_delete_all_instances() {
    local port yes=

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --yes)
            yes=1
            shift
            ;;
        --confirm)
            [[ ${2:-} == DELETE-HOP ]] || return 1
            yes=1
            shift 2
            ;;
        *)
            tuic_hop_fail "无法识别 TUIC Port-Hopping delete-all 参数: $1"
            return 1
            ;;
        esac
    done
    [[ $yes ]] || {
        tuic_hop_fail "删除全部 TUIC Port-Hopping 实例需要 --yes 或 --confirm DELETE-HOP。"
        return 1
    }
    while IFS= read -r port; do
        [[ $port ]] || continue
        tuic_hop_delete_instance "$port" --yes || return 1
    done < <(tuic_hop_list_instances)
    tuic_hop_warn "通用 apply script 与 systemd template 默认保留；如需清理请人工确认后删除。"
}

tuic_hop_report_residuals() {
    local real_port=${1:-}
    local cfg nft_file table service range_start range_end

    if [[ $real_port ]]; then
        cfg=$(tuic_hop_get_config_file "$real_port")
        nft_file=$(tuic_hop_get_nft_rule_file "$real_port")
        table=$(tuic_hop_get_nft_table_name "$real_port")
        service=$(tuic_hop_get_service_name "$real_port")
        if [[ -f $cfg ]]; then
            range_start=$(tuic_hop_read_env_value "$cfg" RANGE_START 2>/dev/null || true)
            range_end=$(tuic_hop_read_env_value "$cfg" RANGE_END 2>/dev/null || true)
        fi
    else
        cfg="${TUIC_HOP_INSTANCE_DIR}/PORT.env"
        nft_file="${TUIC_HOP_NFT_RULE_DIR}/tuic-port-hopping-PORT.nft"
        table="${TUIC_HOP_NFT_TABLE_PREFIX}PORT"
        service="tuic-port-hopping@PORT.service"
    fi

    tuic_hop_blank
    tuic_hop_print ">>> TUIC Port-Hopping 残留检查"
    tuic_hop_kv "实例配置" "$cfg"
    tuic_hop_kv "nft rule file" "$nft_file"
    tuic_hop_kv "nft table" "inet $table"
    tuic_hop_kv "systemd service" "$service"
    tuic_hop_kv "apply script" "$TUIC_HOP_APPLY_SCRIPT"
    tuic_hop_kv "systemd template" "$TUIC_HOP_SYSTEMD_TEMPLATE"
    if [[ $real_port && $range_start && $range_end ]]; then
        tuic_hop_kv "UFW rules" "${real_port}/udp, ${range_start}:${range_end}/udp"
    elif [[ $real_port ]]; then
        tuic_hop_kv "UFW rules" "${real_port}/udp, RANGE_START:RANGE_END/udp"
    else
        tuic_hop_kv "UFW rules" "REAL_PORT/udp, RANGE_START:RANGE_END/udp"
    fi
}

tuic_hop_show_client_hint() {
    local real_port=$1 cfg range_start range_end interval

    tuic_hop_validate_port "$real_port" || return 1
    cfg=$(tuic_hop_get_config_file "$real_port")
    tuic_hop_validate_env_file "$cfg" || return 1
    range_start=$(tuic_hop_read_env_value "$cfg" RANGE_START)
    range_end=$(tuic_hop_read_env_value "$cfg" RANGE_END)
    interval=$(tuic_hop_read_env_value "$cfg" HOP_INTERVAL 2>/dev/null || printf '%s\n' "$TUIC_HOP_DEFAULT_INTERVAL")

    tuic_hop_blank
    tuic_hop_print ">>> TUIC Port-Hopping 客户端模板提示"
    tuic_hop_kv "真实端口" "$real_port"
    tuic_hop_kv "跳跃范围" "${range_start}-${range_end}"
    tuic_hop_kv "推荐 interval" "${interval}s"
    tuic_hop_print "Surge/Surgio 示例："
    printf 'port-hopping="%s;%s-%s", port-hopping-interval=%s\n' "$real_port" "$range_start" "$range_end" "$interval"
    tuic_hop_warn "该输出仅为客户端模板提示，不会修改客户端配置。"
}

tuic_hop_show_tcpdump_hint() {
    local real_port=$1 cfg range_start range_end

    tuic_hop_validate_port "$real_port" || return 1
    cfg=$(tuic_hop_get_config_file "$real_port")
    tuic_hop_validate_env_file "$cfg" || return 1
    range_start=$(tuic_hop_read_env_value "$cfg" RANGE_START)
    range_end=$(tuic_hop_read_env_value "$cfg" RANGE_END)

    tuic_hop_blank
    tuic_hop_print ">>> TUIC Port-Hopping tcpdump 验证命令"
    printf "sudo tcpdump -ni any 'udp port %s or udp portrange %s-%s'\n" "$real_port" "$range_start" "$range_end"
    printf "sudo tcpdump -ni any 'udp portrange %s-%s'\n" "$range_start" "$range_end"
    printf "sudo tcpdump -ni any 'udp port %s'\n" "$real_port"
}

tuic_hop_detect_residual_for_port() {
    local real_port=$1
    local cfg nft_file table service

    tuic_hop_validate_port "$real_port" || return 1
    cfg=$(tuic_hop_get_config_file "$real_port")
    nft_file=$(tuic_hop_get_nft_rule_file "$real_port")
    table=$(tuic_hop_get_nft_table_name "$real_port")
    service=$(tuic_hop_get_service_name "$real_port")
    [[ -e $cfg || -e $nft_file ]] && return 0
    tuic_hop_nft_table_exists "$table" && return 0
    tuic_hop_systemd_is_active "$service" && return 0
    tuic_hop_systemd_is_enabled "$service" && return 0
    return 1
}

tuic_hop_resolve_real_port() {
    local target=$1

    if tuic_hop_validate_port "$target"; then
        printf '%s\n' "$target"
        return 0
    fi
    type tuic_read_config >/dev/null 2>&1 || {
        tuic_hop_fail "无法从配置解析 TUIC 端口: $target"
        return 1
    }
    tuic_read_config "$target" || return 1
    tuic_hop_validate_port "$tuic_port" || return 1
    printf '%s\n' "$tuic_port"
}

tuic_hop_list() {
    local port cfg range_start range_end updated service state

    tuic_hop_print "REAL_PORT RANGE systemd UPDATED_AT"
    while IFS= read -r port; do
        [[ $port ]] || continue
        cfg=$(tuic_hop_get_config_file "$port")
        range_start=$(tuic_hop_read_env_value "$cfg" RANGE_START 2>/dev/null || printf '%s\n' "-")
        range_end=$(tuic_hop_read_env_value "$cfg" RANGE_END 2>/dev/null || printf '%s\n' "-")
        updated=$(tuic_hop_read_env_value "$cfg" UPDATED_AT 2>/dev/null || printf '%s\n' "-")
        service=$(tuic_hop_get_service_name "$port")
        state=inactive
        tuic_hop_systemd_is_active "$service" && state=active
        printf '%s %s-%s/udp %s %s\n' "$port" "$range_start" "$range_end" "$state" "$updated"
    done < <(tuic_hop_list_instances)
}

tuic_hop_parse_enable_update_args() {
    local mode=$1
    shift
    local target=${1:-}

    [[ $target ]] || {
        tuic_hop_fail "Usage: sing-box tuic hop $mode <config|port> [--range auto|START-END] [--interval SEC]"
        return 1
    }
    shift
    TUIC_HOP_REAL_PORT=$(tuic_hop_resolve_real_port "$target") || return 1
    TUIC_HOP_RANGE_ARG=auto
    TUIC_HOP_INTERVAL=$TUIC_HOP_DEFAULT_INTERVAL
    TUIC_HOP_ALLOW_MISSING_LISTENER=
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --range)
            [[ ${2:-} ]] || return 1
            TUIC_HOP_RANGE_ARG=$2
            shift 2
            ;;
        --interval)
            [[ ${2:-} ]] || return 1
            TUIC_HOP_INTERVAL=$2
            shift 2
            ;;
        --allow-missing-listener)
            TUIC_HOP_ALLOW_MISSING_LISTENER=1
            shift
            ;;
        --yes)
            TUIC_HOP_YES=1
            TUIC_HOP_ALLOW_MISSING_LISTENER=1
            shift
            ;;
        *)
            tuic_hop_fail "无法识别 TUIC Port-Hopping 参数: $1"
            return 1
            ;;
        esac
    done
}

tuic_hop_main() {
    local subcommand=${1:-list}
    local target real_port

    case "$subcommand" in
    enable | update)
        shift
        tuic_hop_reset_state
        tuic_hop_parse_enable_update_args "$subcommand" "$@" || return 1
        tuic_hop_create_or_update_instance "$TUIC_HOP_REAL_PORT" "$TUIC_HOP_RANGE_ARG" "$TUIC_HOP_INTERVAL" "$TUIC_HOP_ALLOW_MISSING_LISTENER"
        ;;
    status)
        shift
        target=${1:-}
        [[ $target ]] || return 1
        real_port=$(tuic_hop_resolve_real_port "$target") || return 1
        tuic_hop_status_instance "$real_port"
        ;;
    validate)
        shift
        target=${1:-}
        [[ $target ]] || return 1
        real_port=$(tuic_hop_resolve_real_port "$target") || return 1
        tuic_hop_validate_instance "$real_port"
        ;;
    hint)
        shift
        target=${1:-}
        [[ $target ]] || return 1
        real_port=$(tuic_hop_resolve_real_port "$target") || return 1
        tuic_hop_show_client_hint "$real_port"
        ;;
    tcpdump)
        shift
        target=${1:-}
        [[ $target ]] || return 1
        real_port=$(tuic_hop_resolve_real_port "$target") || return 1
        tuic_hop_show_tcpdump_hint "$real_port"
        ;;
    delete)
        shift
        target=${1:-}
        [[ $target ]] || return 1
        shift
        real_port=$(tuic_hop_resolve_real_port "$target") || return 1
        tuic_hop_delete_instance "$real_port" "$@"
        ;;
    delete-all)
        shift
        tuic_hop_delete_all_instances "$@"
        ;;
    list)
        tuic_hop_list
        ;;
    menu)
        tuic_hop_menu
        ;;
    -h | --help | help)
        tuic_hop_print "Usage: sing-box tuic hop <enable|update|status|validate|hint|tcpdump|delete|delete-all|list>"
        ;;
    *)
        tuic_hop_fail "无法识别 TUIC Port-Hopping 子命令: $subcommand"
        return 1
        ;;
    esac
}

tuic_hop_menu() {
    local choice target range interval port

    is_main_start=1
    while :; do
        ui_clear
        ui_title "TUIC Port-Hopping 管理" "${is_sh_ver:-}"
        ui_blank
        ui_menu_item 1 "查看实例列表"
        ui_menu_item 2 "启用 / 更新实例"
        ui_menu_item 3 "查看实例状态"
        ui_menu_item 4 "验证实例"
        ui_menu_item 5 "显示客户端参数"
        ui_menu_item 6 "显示 tcpdump 命令"
        ui_menu_item 7 "删除实例"
        ui_menu_item 8 "删除全部实例"
        ui_menu_item 0 "返回上一级"
        ui_blank
        ui_read_raw choice "请输入选项编号（0 返回）： " || return 1
        case "$choice" in
        1)
            tuic_hop_list
            ui_pause
            ;;
        2)
            ui_read_or_cancel target "请输入 TUIC 配置名或真实 UDP 端口（q 取消）： " || continue
            ui_read_or_cancel range "请输入跳跃范围（auto 或 START-END，默认 auto，q 取消）： " || continue
            range=${range:-auto}
            ui_read_or_cancel interval "请输入推荐 interval 秒数（默认 ${TUIC_HOP_DEFAULT_INTERVAL}，q 取消）： " || continue
            interval=${interval:-$TUIC_HOP_DEFAULT_INTERVAL}
            ui_confirm_token "确认写入 TUIC Port-Hopping 系统对象？" "APPLY-HOP" || {
                ui_warn "已取消。"
                continue
            }
            port=$(tuic_hop_resolve_real_port "$target") || {
                ui_pause
                continue
            }
            tuic_hop_create_or_update_instance "$port" "$range" "$interval" 1
            ui_pause
            ;;
        3 | 4 | 5 | 6 | 7)
            ui_read_or_cancel target "请输入 TUIC 配置名或真实 UDP 端口（q 取消）： " || continue
            port=$(tuic_hop_resolve_real_port "$target") || {
                ui_pause
                continue
            }
            case "$choice" in
            3) tuic_hop_status_instance "$port" ;;
            4) tuic_hop_validate_instance "$port" ;;
            5) tuic_hop_show_client_hint "$port" ;;
            6) tuic_hop_show_tcpdump_hint "$port" ;;
            7)
                ui_confirm_token "确认删除该 TUIC Port-Hopping 实例？" "DELETE-HOP" || {
                    ui_warn "已取消。"
                    ui_pause
                    continue
                }
                tuic_hop_delete_instance "$port" --yes
                ;;
            esac
            ui_pause
            ;;
        8)
            ui_confirm_token "确认删除全部 TUIC Port-Hopping 实例？" "DELETE-HOP" || {
                ui_warn "已取消。"
                ui_pause
                continue
            }
            tuic_hop_delete_all_instances --yes
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
