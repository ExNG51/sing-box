#!/bin/bash

is_backup_dir=${is_backup_dir:-${is_core_dir:-/etc/sing-box}/backups}

IS_BACKUP_ACTIVE=${IS_BACKUP_ACTIVE:-false}
IS_BACKUP_OPERATION=
IS_BACKUP_TXN_ID=
IS_BACKUP_TXN_DIR=
IS_BACKUP_CREATED_AT=
IS_BACKUP_RECORDED_PATHS=$'\n'
IS_BACKUP_MANIFEST_FILES=()
SHELL_ALIAS_BLOCK_BEGIN="# >>> sing-box script aliases >>>"
SHELL_ALIAS_BLOCK_END="# <<< sing-box script aliases <<<"

backup_warn() {
    if type warn >/dev/null 2>&1; then
        warn "$*"
    else
        printf 'WARN: %s\n' "$*" >&2
    fi
}

backup_ui_warn() {
    if type ui_warn >/dev/null 2>&1; then
        ui_warn "$*"
    else
        backup_warn "$*"
    fi
}

backup_die() {
    if type err >/dev/null 2>&1; then
        err "$*"
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
    return 1
}

backup_json_escape() {
    local value=${1-}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

shell_single_quote() {
    local value=${1-}

    value=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$value"
}

backup_sha256_before() {
    local path=$1
    local actual
    [[ -f $path ]] || {
        printf 'null'
        return 0
    }
    if type -P sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$path" | awk '{print $1}')
    elif type -P shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$path" | awk '{print $1}')
    else
        backup_warn "缺少 sha256sum 或 shasum, manifest 将 sha256_before 记录为 null: $path"
        printf 'null'
        return 0
    fi
    printf '%s' "$actual"
}

backup_path_type() {
    local path=$1
    if [[ -L $path ]]; then
        printf 'symlink'
    elif [[ -f $path ]]; then
        printf 'file'
    elif [[ -d $path ]]; then
        printf 'directory'
    else
        printf 'missing'
    fi
}

backup_path_recorded() {
    local path=$1
    case $IS_BACKUP_RECORDED_PATHS in
    *$'\n'"$path"$'\n'*) return 0 ;;
    *) return 1 ;;
    esac
}

backup_relative_path() {
    local path=$1
    case $path in
    "${is_config_json:-}" | "${is_core_dir:-}"/config.json)
        printf 'config.json'
        ;;
    "${is_conf_dir:-}"/*)
        printf 'conf/%s' "${path#"${is_conf_dir:-}"/}"
        ;;
    "${is_caddyfile:-}")
        printf 'Caddyfile'
        ;;
    "${is_caddy_conf:-}"/*)
        printf 'caddy-conf/%s' "${path#"${is_caddy_conf:-}"/}"
        ;;
    "${is_core_bin:-}")
        printf 'bin/%s' "$(basename "$path")"
        ;;
    "${is_shell_profile:-/root/.bashrc}" | "/root/.bashrc")
        printf 'root/.bashrc'
        ;;
    */lib/systemd/system/*)
        printf 'lib/systemd/system/%s' "${path##*/lib/systemd/system/}"
        ;;
    */etc/systemd/system/*)
        printf 'etc/systemd/system/%s' "${path##*/etc/systemd/system/}"
        ;;
    */etc/init.d/*)
        printf 'etc/init.d/%s' "${path##*/etc/init.d/}"
        ;;
    */usr/local/bin/*)
        printf 'usr/local/bin/%s' "${path##*/usr/local/bin/}"
        ;;
    *)
        printf '%s' "${path#/}"
        ;;
    esac
}

record_manifest_file() {
    local path=$1
    local backup_path=$2
    local type=$3
    local existed=$4
    local sha256_before=$5
    local path_json backup_json sha_json type_json

    path_json=$(backup_json_escape "$path")
    type_json=$(backup_json_escape "$type")
    if [[ $backup_path ]]; then
        backup_json="\"$(backup_json_escape "$backup_path")\""
    else
        backup_json=null
    fi
    if [[ $sha256_before && $sha256_before != null ]]; then
        sha_json="\"$(backup_json_escape "$sha256_before")\""
    else
        sha_json=null
    fi

    IS_BACKUP_MANIFEST_FILES+=("{\"path\":\"$path_json\",\"backup_path\":$backup_json,\"type\":\"$type_json\",\"existed\":$existed,\"sha256_before\":$sha_json}")
    IS_BACKUP_RECORDED_PATHS+="$path"$'\n'
}

init_backup_transaction() {
    local operation=${1:-managed-write}
    local safe_operation timestamp candidate

    [[ $IS_BACKUP_ACTIVE == true ]] && return 0

    # 每个脚本操作只创建一个事务目录，后续 safe_* 写入都会复用它。
    safe_operation=$(printf '%s' "$operation" | tr -c 'A-Za-z0-9_.-' '_')
    timestamp=$(date -u '+%Y-%m-%d_%H%M%S')
    candidate="${timestamp}_${safe_operation}"

    mkdir -p "$is_backup_dir" || {
        backup_die "无法创建备份目录: $is_backup_dir"
        return 1
    }
    if [[ -e $is_backup_dir/$candidate ]]; then
        candidate="${candidate}_$$"
    fi

    IS_BACKUP_OPERATION=$operation
    IS_BACKUP_TXN_ID=$candidate
    IS_BACKUP_TXN_DIR=$is_backup_dir/$candidate
    IS_BACKUP_CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    IS_BACKUP_RECORDED_PATHS=$'\n'
    IS_BACKUP_MANIFEST_FILES=()
    mkdir -p "$IS_BACKUP_TXN_DIR" || {
        backup_die "无法创建备份事务目录: $IS_BACKUP_TXN_DIR"
        return 1
    }
    IS_BACKUP_ACTIVE=true
}

begin_backup_transaction_if_needed() {
    local operation=${1:-managed-write}
    if [[ $IS_BACKUP_ACTIVE == true ]]; then
        return 1
    fi
    init_backup_transaction "$operation"
    return 0
}

backup_path_before_write() {
    local path=$1
    local existed=false
    local type=missing
    local backup_rel=
    local backup_full=
    local sha256_before=null

    [[ $path ]] || return 0
    [[ $IS_BACKUP_ACTIVE == true ]] || init_backup_transaction managed-write || return 1
    backup_path_recorded "$path" && return 0

    backup_rel=$(backup_relative_path "$path")
    if [[ -e $path || -L $path ]]; then
        existed=true
        type=$(backup_path_type "$path")
        sha256_before=$(backup_sha256_before "$path")

        # 删除 /etc/sing-box 这类包含 backups 的目录时，避免把备份目录复制进自身。
        if [[ -d $path && ${is_backup_dir:-} == "$path"/* ]]; then
            backup_warn "跳过包含备份目录的完整目录快照，仅记录 manifest: $path"
            backup_rel=
        else
            backup_full=$IS_BACKUP_TXN_DIR/$backup_rel
            mkdir -p "$(dirname "$backup_full")" || return 1
            cp -a "$path" "$backup_full" || {
                backup_die "备份失败: $path"
                return 1
            }
        fi
    fi

    record_manifest_file "$path" "$backup_rel" "$type" "$existed" "$sha256_before"
}

backup_glob_before_write() {
    local pattern=$1
    local path
    local matched=false

    # glob 只备份已经存在的匹配项；新建文件由 safe_write_file 单独记录 existed=false。
    while IFS= read -r path; do
        matched=true
        backup_path_before_write "$path" || return 1
    done < <(compgen -G "$pattern" || true)
    [[ $matched == true || $pattern ]]
}

backup_standard_managed_paths() {
    backup_path_before_write "${is_config_json:-${is_core_dir:-/etc/sing-box}/config.json}"
    backup_glob_before_write "${is_conf_dir:-${is_core_dir:-/etc/sing-box}/conf}/*.json"
    backup_path_before_write "${is_caddyfile:-/etc/caddy/Caddyfile}"
    backup_glob_before_write "${is_caddy_conf:-/etc/caddy/conf}/*.conf"
    backup_glob_before_write "${is_caddy_conf:-/etc/caddy/conf}/*.conf.add"
    backup_path_before_write "/lib/systemd/system/${is_core:-sing-box}.service"
    backup_path_before_write "/etc/systemd/system/${is_core:-sing-box}.service"
    backup_path_before_write "/lib/systemd/system/caddy.service"
    backup_path_before_write "/etc/systemd/system/caddy.service"
    backup_path_before_write "/etc/init.d/${is_core:-sing-box}"
    backup_path_before_write "/etc/init.d/caddy"
    backup_path_before_write "${is_core_bin:-/usr/local/bin/sing-box}"
    backup_path_before_write "${is_sh_bin:-/usr/local/bin/sing-box}"
    backup_path_before_write "${is_sh_bin/${is_core:-sing-box}/sb}"
    backup_path_before_write "${is_shell_profile:-/root/.bashrc}"
}

finalize_backup_transaction() {
    local manifest_tmp latest_tmp
    local script_repo=${is_sh_repo:-ExNG51/sing-box}
    local script_version=${is_sh_ver:-unknown}
    local sing_before=${is_core_ver:-unknown}
    local init_system=${is_init_system:-unknown}
    local i

    [[ $IS_BACKUP_ACTIVE == true ]] || return 0

    manifest_tmp=$IS_BACKUP_TXN_DIR/manifest.json.tmp
    {
        printf '{\n'
        printf '  "schema_version":1,\n'
        printf '  "created_at":"%s",\n' "$(backup_json_escape "$IS_BACKUP_CREATED_AT")"
        printf '  "operation":"%s",\n' "$(backup_json_escape "$IS_BACKUP_OPERATION")"
        printf '  "script_repo":"%s",\n' "$(backup_json_escape "$script_repo")"
        printf '  "script_version":"%s",\n' "$(backup_json_escape "$script_version")"
        printf '  "sing_box_version_before":"%s",\n' "$(backup_json_escape "$sing_before")"
        printf '  "sing_box_version_after":null,\n'
        printf '  "init_system":"%s",\n' "$(backup_json_escape "$init_system")"
        printf '  "files":[\n'
        for ((i = 0; i < ${#IS_BACKUP_MANIFEST_FILES[@]}; i++)); do
            printf '    %s' "${IS_BACKUP_MANIFEST_FILES[$i]}"
            [[ $i -lt $((${#IS_BACKUP_MANIFEST_FILES[@]} - 1)) ]] && printf ','
            printf '\n'
        done
        printf '  ]\n'
        printf '}\n'
    } >"$manifest_tmp" || return 1
    mv -f "$manifest_tmp" "$IS_BACKUP_TXN_DIR/manifest.json" || return 1

    # latest 指针使用临时文件 + mv，避免读到半写入内容。
    latest_tmp=$is_backup_dir/latest.tmp.$$
    printf '%s\n' "$IS_BACKUP_TXN_ID" >"$latest_tmp" || return 1
    mv -f "$latest_tmp" "$is_backup_dir/latest" || return 1

    IS_LAST_BACKUP_TXN_DIR=$IS_BACKUP_TXN_DIR
    IS_BACKUP_ACTIVE=false
}

safe_write_file() {
    local path=$1
    local dir base tmp
    shift || true

    # 写入目标文件前先保存旧状态；不存在也会进入 manifest，供 rollback 删除新文件。
    backup_path_before_write "$path" || return 1
    dir=$(dirname "$path")
    base=$(basename "$path")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.${base}.tmp.XXXXXX") || return 1
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "$1" >"$tmp" || return 1
    else
        cat >"$tmp" || return 1
    fi
    mv -f "$tmp" "$path"
}

safe_append_file() {
    local path=$1
    local text=$2

    # append 也会改变生产文件，因此必须先备份原文件。
    backup_path_before_write "$path" || return 1
    mkdir -p "$(dirname "$path")" || return 1
    printf '%s\n' "$text" >>"$path"
}

safe_ensure_dir() {
    local path=$1

    # mkdir -p 会创建生产目录；不存在时也记录 existed=false，便于 rollback 删除新目录入口。
    backup_path_before_write "$path" || return 1
    mkdir -p "$path"
}

safe_copy_file() {
    local src=$1
    local dst=$2

    # copy 覆盖目标前只备份目标，rollback 可信来源仍然是 manifest 指向的快照。
    backup_path_before_write "$dst" || return 1
    mkdir -p "$(dirname "$dst")" || return 1
    cp -af "$src" "$dst"
}

safe_copy_contents() {
    local src_dir=$1
    local dst_dir=$2

    backup_path_before_write "$dst_dir" || return 1
    mkdir -p "$dst_dir" || return 1
    cp -af "$src_dir"/. "$dst_dir"/
}

safe_move_file() {
    local src=$1
    local dst=$2

    backup_path_before_write "$dst" || return 1
    mkdir -p "$(dirname "$dst")" || return 1
    mv -f "$src" "$dst"
}

safe_link_file() {
    local target=$1
    local link_path=$2

    backup_path_before_write "$link_path" || return 1
    mkdir -p "$(dirname "$link_path")" || return 1
    ln -sf "$target" "$link_path"
}

is_managed_shell_profile_path() {
    local path=${1-}

    [[ $path ]] || return 1
    [[ $path == "${is_shell_profile:-/root/.bashrc}" ]] && return 0
    [[ ${is_profile_file:-} && $path == "$is_profile_file" ]] && return 0
    [[ $path == "/root/.bashrc" ]] && return 0
    return 1
}

backup_shell_profile_before_write() {
    local profile=${1:-${is_shell_profile:-/root/.bashrc}}

    # shell profile 只能通过受管入口修改；这里不允许删除 /root/.bashrc。
    is_managed_shell_profile_path "$profile" || {
        backup_die "拒绝修改非脚本管理 shell profile: $profile"
        return 1
    }
    [[ ! -d $profile || -L $profile ]] || {
        backup_die "拒绝把目录当作 shell profile 修改: $profile"
        return 1
    }
    backup_path_before_write "$profile"
}

remove_shell_alias_block() {
    local profile=${1:-${is_shell_profile:-/root/.bashrc}}

    [[ -f $profile ]] || return 0
    # 只识别固定 marker，删除范围严格限定在 marker block 内。
    awk -v begin="$SHELL_ALIAS_BLOCK_BEGIN" -v end="$SHELL_ALIAS_BLOCK_END" '
        $0 == begin { in_block = 1; next }
        $0 == end {
            if (in_block) {
                in_block = 0
                next
            }
        }
        !in_block { print }
    ' "$profile"
}

render_shell_alias_block() {
    local sh_bin=${is_sh_bin:-/usr/local/bin/sing-box}
    local core_alias=${is_core:-sing-box}
    local quoted_sh_bin

    quoted_sh_bin=$(shell_single_quote "$sh_bin")
    printf '%s\n' "$SHELL_ALIAS_BLOCK_BEGIN"
    printf 'alias sb=%s\n' "$quoted_sh_bin"
    printf 'alias %s=%s\n' "$core_alias" "$quoted_sh_bin"
    printf '%s\n' "$SHELL_ALIAS_BLOCK_END"
}

safe_update_shell_aliases() {
    local profile=${1:-${is_shell_profile:-/root/.bashrc}}
    local dir base tmp

    # 写 alias 前先备份原 profile；重复安装先移除旧 block，再写入新 block。
    backup_shell_profile_before_write "$profile" || return 1
    dir=$(dirname "$profile")
    base=$(basename "$profile")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.${base}.tmp.XXXXXX") || return 1
    remove_shell_alias_block "$profile" >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    render_shell_alias_block >>"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$profile"
}

safe_remove_shell_aliases() {
    local profile=${1:-${is_shell_profile:-/root/.bashrc}}
    local dir base tmp

    # 卸载只删除 marker block，保留 block 外用户自定义内容。
    [[ -e $profile || -L $profile ]] || return 0
    backup_shell_profile_before_write "$profile" || return 1
    dir=$(dirname "$profile")
    base=$(basename "$profile")
    tmp=$(mktemp "$dir/.${base}.tmp.XXXXXX") || return 1
    remove_shell_alias_block "$profile" >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$profile"
}

strip_trailing_slashes_for_remove() {
    local path=$1
    while [[ $path != "/" && $path == */ ]]; do
        path=${path%/}
    done
    printf '%s' "$path"
}

managed_remove_prefix() {
    local marker="/etc/${is_core:-sing-box}"
    local prefix=${is_core_dir:-/etc/${is_core:-sing-box}}

    if [[ $prefix == *"$marker" ]]; then
        printf '%s' "${prefix%"$marker"}"
    fi
}

path_is_direct_child_with_suffix() {
    local path=$1
    local dir=$2
    local suffix=$3
    local rel

    [[ $path == "$dir"/* ]] || return 1
    rel=${path#"$dir"/}
    [[ $rel != */* && $rel == *"$suffix" ]]
}

path_is_direct_child_with_prefix_suffix() {
    local path=$1
    local dir=$2
    local prefix=$3
    local suffix=$4
    local rel

    [[ $path == "$dir"/* ]] || return 1
    rel=${path#"$dir"/}
    [[ $rel != */* && $rel == "$prefix"* && $rel == *"$suffix" ]]
}

path_is_under_dir() {
    local path=$1
    local dir=$2

    [[ $path == "$dir"/* && $path != "$dir" ]]
}

is_managed_remove_path() {
    local path=$1
    local prefix
    local bin_dir sh_bin sb_bin log_dir
    local hop_instance_dir hop_nft_dir hop_apply_script hop_systemd_template

    path=$(strip_trailing_slashes_for_remove "$path")
    prefix=$(managed_remove_prefix)
    bin_dir=${is_core_dir:-${prefix}/etc/${is_core:-sing-box}}/bin
    sh_bin=${is_sh_bin:-${prefix}/usr/local/bin/${is_core:-sing-box}}
    sb_bin=${sh_bin/${is_core:-sing-box}/sb}
    log_dir=${is_log_dir:-${prefix}/var/log/${is_core:-sing-box}}
    hop_instance_dir=${TUIC_HOP_INSTANCE_DIR:-${prefix}/etc/tuic-port-hopping/instances}
    hop_nft_dir=${TUIC_HOP_NFT_RULE_DIR:-${prefix}/etc/nftables.d}
    hop_apply_script=${TUIC_HOP_APPLY_SCRIPT:-${prefix}/usr/local/sbin/apply-tuic-port-hopping.sh}
    hop_systemd_template=${TUIC_HOP_SYSTEMD_TEMPLATE:-${prefix}/etc/systemd/system/tuic-port-hopping@.service}

    # allowlist 只包含脚本明确管理的文件或窄目录，禁止删除宽泛系统目录。
    [[ $path == "${is_config_json:-${prefix}/etc/${is_core:-sing-box}/config.json}" ]] && return 0
    path_is_direct_child_with_suffix "$path" "${is_conf_dir:-${prefix}/etc/${is_core:-sing-box}/conf}" ".json" && return 0
    [[ $path == "${is_core_bin:-$bin_dir/${is_core:-sing-box}}" ]] && return 0
    path_is_under_dir "$path" "${is_sh_dir:-${prefix}/etc/${is_core:-sing-box}/sh}" && return 0
    [[ $path == "${is_caddyfile:-${prefix}/etc/caddy/Caddyfile}" ]] && return 0
    path_is_direct_child_with_suffix "$path" "${is_caddy_conf:-${prefix}/etc/caddy/conf}" ".conf" && return 0
    path_is_direct_child_with_suffix "$path" "${is_caddy_conf:-${prefix}/etc/caddy/conf}" ".conf.add" && return 0
    [[ $path == "${prefix}/lib/systemd/system/${is_core:-sing-box}.service" ]] && return 0
    [[ $path == "${prefix}/lib/systemd/system/caddy.service" ]] && return 0
    [[ $path == "${prefix}/etc/systemd/system/${is_core:-sing-box}.service" ]] && return 0
    [[ $path == "${prefix}/etc/systemd/system/caddy.service" ]] && return 0
    [[ $path == "${prefix}/etc/init.d/${is_core:-sing-box}" ]] && return 0
    [[ $path == "${prefix}/etc/init.d/caddy" ]] && return 0
    [[ $path == "$sh_bin" || $path == "$sb_bin" ]] && return 0
    [[ $path == "${prefix}/usr/local/bin/${is_core:-sing-box}" || $path == "${prefix}/usr/local/bin/sb" ]] && return 0
    [[ $path == "${is_caddy_bin:-${prefix}/usr/local/bin/caddy}" ]] && return 0
    [[ $path == "$log_dir" ]] && return 0
    path_is_under_dir "$path" "$log_dir" && return 0
    path_is_direct_child_with_suffix "$path" "$hop_instance_dir" ".env" && return 0
    path_is_direct_child_with_prefix_suffix "$path" "$hop_nft_dir" "tuic-port-hopping-" ".nft" && return 0
    [[ $path == "$hop_apply_script" ]] && return 0
    [[ $path == "$hop_systemd_template" ]] && return 0
    return 1
}

assert_safe_remove_path() {
    local path=${1-}
    local normalized
    local backup_root

    # 删除操作先做硬性拒绝，避免空变量、相对路径或宽目录进入备份/删除流程。
    [[ $path ]] || {
        backup_die "拒绝删除空路径."
        return 1
    }
    [[ $path == /* ]] || {
        backup_die "拒绝删除相对路径: $path"
        return 1
    }
    case $path in
    "." | ".." | "*" | ./* | ../* | *"/../"* | *"/.." | *"/./"* | *"/.")
        backup_die "拒绝删除危险路径: $path"
        return 1
        ;;
    esac

    normalized=$(strip_trailing_slashes_for_remove "$path")
    case $normalized in
    / | /etc | /usr | /lib | /root | /var | /tmp)
        backup_die "拒绝删除系统宽目录: $path"
        return 1
        ;;
    esac

    backup_root=$(strip_trailing_slashes_for_remove "${is_backup_dir:-${is_core_dir:-/etc/sing-box}/backups}")
    if [[ $normalized == "$backup_root" || $normalized == "$backup_root"/* ]]; then
        backup_die "拒绝删除备份目录或其内容: $path"
        return 1
    fi

    is_managed_remove_path "$normalized" || {
        backup_die "拒绝删除非脚本管理路径: $path"
        return 1
    }
}

safe_remove_path() {
    local path

    [[ $# -gt 0 ]] || {
        backup_die "拒绝删除空参数列表."
        return 1
    }
    # 先验证全部参数，再备份和删除，避免第二个参数危险时第一个安全路径已被删除。
    for path in "$@"; do
        assert_safe_remove_path "$path" || return 1
    done
    # 删除前记录 existed=true/false；rollback 通过 existed=false 判断是否删除新建文件。
    for path in "$@"; do
        path=$(strip_trailing_slashes_for_remove "$path")
        backup_path_before_write "$path" || return 1
        rm -rf -- "$path" || return 1
    done
}

safe_sed_inplace() {
    local path=$1
    local dir base tmp
    shift

    backup_path_before_write "$path" || return 1
    dir=$(dirname "$path")
    base=$(basename "$path")
    tmp=$(mktemp "$dir/.${base}.sed.XXXXXX") || return 1
    sed "$@" "$path" >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$path"
}

safe_chmod_path() {
    local mode=$1
    local path
    shift

    for path in "$@"; do
        backup_path_before_write "$path" || return 1
    done
    chmod "$mode" "$@"
}

rollback_require_jq() {
    type -P jq >/dev/null 2>&1 || {
        backup_die "rollback 需要 jq 解析 manifest.json."
        return 1
    }
}

rollback_latest_dir() {
    local latest_file=$is_backup_dir/latest
    local latest_id

    [[ -f $latest_file ]] || {
        backup_die "未找到 rollback latest 指针: $latest_file"
        return 1
    }
    latest_id=$(sed -n '1p' "$latest_file")
    [[ $latest_id ]] || {
        backup_die "rollback latest 指针为空: $latest_file"
        return 1
    }
    [[ -d $is_backup_dir/$latest_id ]] || {
        backup_die "rollback latest 指向不存在的目录: $latest_id"
        return 1
    }
    printf '%s' "$is_backup_dir/$latest_id"
}

rollback_validate_manifest() {
    local manifest=$1

    [[ -f $manifest ]] || {
        backup_die "rollback manifest 缺失: $manifest"
        return 1
    }
    rollback_require_jq || return 1
    jq -e '.schema_version == 1 and (.files | type == "array")' "$manifest" >/dev/null 2>&1 || {
        backup_die "rollback manifest 损坏或 schema 不受支持: $manifest"
        return 1
    }
}

rollback_preflight_backup_files() {
    local txn_dir=$1
    local manifest=$2
    local rel

    while IFS= read -r rel; do
        [[ $rel ]] || {
            backup_die "rollback manifest 中存在缺失 backup_path 的 restore 项."
            return 1
        }
        [[ -e $txn_dir/$rel || -L $txn_dir/$rel ]] || {
            backup_die "rollback 备份文件缺失，拒绝部分恢复: $rel"
            return 1
        }
    done < <(jq -r '.files[] | select(.existed == true) | (.backup_path // "")' "$manifest")
}

rollback_print_plan() {
    local manifest=$1
    local created operation

    created=$(jq -r '.created_at // "unknown"' "$manifest")
    operation=$(jq -r '.operation // "unknown"' "$manifest")
    printf 'Rollback manifest: %s (%s)\n' "$created" "$operation"
    printf 'Rollback plan:\n'
    jq -r '.files[] | if .existed == true then "- restore: \(.path)" else "- delete: \(.path)" end' "$manifest"
}

rollback_confirm() {
    local reply
    printf '是否继续回滚？ [y/N，q 取消]: '
    read -r reply || reply=
    case $reply in
    y | Y) return 0 ;;
    n | N | no | NO | No | q | Q | "")
        backup_ui_warn "已取消回滚。"
        return 1
        ;;
    *)
        backup_ui_warn "请输入 y、n 或 q。"
        return 1
        ;;
    esac
}

rollback_manifest_touches() {
    local manifest=$1
    local pattern=$2
    jq -e --arg pattern "$pattern" '.files[].path | test($pattern)' "$manifest" >/dev/null 2>&1
}

rollback_service_action() {
    local action=$1
    local name=$2

    [[ ${IS_BACKUP_ROLLBACK_SKIP_SERVICES:-false} == true ]] && return 0
    if [[ ${is_systemd:-} || $(type -P systemctl 2>/dev/null) ]]; then
        if [[ $action == daemon-reload ]]; then
            systemctl daemon-reload 2>/dev/null || true
        else
            systemctl "$action" "$name" 2>/dev/null || true
        fi
    elif [[ ${is_openrc:-} || $(type -P rc-service 2>/dev/null) ]]; then
        case $action in
        stop | restart | start)
            rc-service "$name" "$action" 2>/dev/null || true
            ;;
        esac
    fi
}

rollback_prepare_pre_backup() {
    local manifest=$1
    local path

    # rollback 自身执行前再保存一次当前状态，避免恢复操作误伤后无法回到现场。
    init_backup_transaction pre-rollback || return 1
    while IFS= read -r path; do
        backup_path_before_write "$path" || return 1
    done < <(jq -r '.files[].path' "$manifest")
    finalize_backup_transaction
}

rollback_apply_manifest() {
    local txn_dir=$1
    local manifest=$2
    local existed path rel src

    while IFS=$'\t' read -r existed path rel; do
        if [[ $existed == true ]]; then
            src=$txn_dir/$rel
            mkdir -p "$(dirname "$path")" || return 1
            rm -rf -- "$path" || return 1
            cp -a "$src" "$path" || return 1
        else
            rm -rf -- "$path" || return 1
        fi
    done < <(jq -r '.files[] | [(.existed | tostring), .path, (.backup_path // "")] | @tsv' "$manifest")
}

rollback_latest_backup() {
    local assume_yes=false
    local dry_run=false
    local txn_dir manifest

    while [[ $# -gt 0 ]]; do
        case $1 in
        --yes | -y)
            assume_yes=true
            shift
            ;;
        --dry-run | --plan)
            dry_run=true
            shift
            ;;
        *)
            backup_die "未知 rollback 参数: $1"
            return 1
            ;;
        esac
    done

    txn_dir=$(rollback_latest_dir) || return 1
    manifest=$txn_dir/manifest.json
    rollback_validate_manifest "$manifest" || return 1
    rollback_preflight_backup_files "$txn_dir" "$manifest" || return 1
    rollback_print_plan "$manifest"
    [[ $dry_run == true ]] && return 0
    [[ $assume_yes == true ]] || rollback_confirm || return 1

    rollback_manifest_touches "$manifest" 'sing-box|/conf/|config\.json' && rollback_service_action stop "${is_core:-sing-box}"
    rollback_manifest_touches "$manifest" 'caddy|Caddyfile' && rollback_service_action stop caddy

    rollback_prepare_pre_backup "$manifest" || return 1
    rollback_apply_manifest "$txn_dir" "$manifest" || return 1

    rollback_service_action daemon-reload "${is_core:-sing-box}"
    rollback_manifest_touches "$manifest" 'sing-box|/conf/|config\.json' && rollback_service_action restart "${is_core:-sing-box}"
    rollback_manifest_touches "$manifest" 'caddy|Caddyfile' && rollback_service_action restart caddy
    printf 'Rollback complete.\n'
}
