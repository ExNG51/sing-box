#!/bin/bash

ui_init_colors() {
    if [[ ${FORCE_COLOR:-} == 1 ]]; then
        UI_COLOR_ENABLED=1
    elif [[ -n ${NO_COLOR:-} || ${TERM:-} == "dumb" || ! -t 1 ]]; then
        UI_COLOR_ENABLED=
    else
        UI_COLOR_ENABLED=1
    fi

    if [[ ${UI_COLOR_ENABLED:-} ]]; then
        UI_STYLE_BOLD='\033[1m'
        UI_STYLE_DIM='\033[2m'
        UI_STYLE_UNDERLINE='\033[4m'
        UI_COLOR_RED='\033[31m'
        UI_COLOR_YELLOW='\033[33m'
        UI_COLOR_GRAY='\033[90m'
        UI_COLOR_GREEN='\033[92m'
        UI_COLOR_BLUE='\033[94m'
        UI_COLOR_MAGENTA='\033[95m'
        UI_COLOR_CYAN='\033[96m'
        UI_COLOR_RED_BG='\033[41m'
        UI_COLOR_RESET='\033[0m'
    else
        UI_STYLE_BOLD=
        UI_STYLE_DIM=
        UI_STYLE_UNDERLINE=
        UI_COLOR_RED=
        UI_COLOR_YELLOW=
        UI_COLOR_GRAY=
        UI_COLOR_GREEN=
        UI_COLOR_BLUE=
        UI_COLOR_MAGENTA=
        UI_COLOR_CYAN=
        UI_COLOR_RED_BG=
        UI_COLOR_RESET=
    fi

    red=$UI_COLOR_RED
    yellow=$UI_COLOR_YELLOW
    gray=$UI_COLOR_GRAY
    green=$UI_COLOR_GREEN
    blue=$UI_COLOR_BLUE
    magenta=$UI_COLOR_MAGENTA
    cyan=$UI_COLOR_CYAN
    none=$UI_COLOR_RESET
}

ui_print() {
    printf '%b\n' "$*"
}

ui_print_inline() {
    printf '%b' "$*"
}

ui_blank() {
    printf '\n'
}

ui_info() {
    printf '%b\n' "${UI_STYLE_BOLD}${UI_COLOR_CYAN}[i]${UI_COLOR_RESET} $*"
}

ui_ok() {
    printf '%b\n' "${UI_STYLE_BOLD}${UI_COLOR_GREEN}[OK]${UI_COLOR_RESET} $*"
}

ui_warn() {
    printf '%b\n' "${UI_STYLE_BOLD}${UI_COLOR_YELLOW}[WARN]${UI_COLOR_RESET} $*" >&2
}

ui_error() {
    printf '%b\n' "${UI_STYLE_BOLD}${UI_COLOR_RED}[ERROR]${UI_COLOR_RESET} $*" >&2
}

ui_dim() {
    printf '%b\n' "${UI_STYLE_DIM}$*${UI_COLOR_RESET}"
}

ui_rule() {
    printf '%b\n' "${UI_STYLE_BOLD}${UI_COLOR_CYAN}============================================================${UI_COLOR_RESET}"
}

ui_title() {
    ui_rule
    printf '%b\n' "${UI_STYLE_BOLD}${UI_COLOR_CYAN}$1${UI_COLOR_RESET}"
    [[ ${2:-} ]] && printf '%b\n' "${UI_STYLE_BOLD}${UI_COLOR_CYAN}Version: $2${UI_COLOR_RESET}"
    ui_rule
}

ui_menu_item() {
    printf ' %2s. %s\n' "$1" "$2"
}

ui_green_text() {
    printf '%b' "${UI_COLOR_GREEN}$*${UI_COLOR_RESET}"
}

ui_yellow_text() {
    printf '%b' "${UI_COLOR_YELLOW}$*${UI_COLOR_RESET}"
}

ui_red_text() {
    printf '%b' "${UI_COLOR_RED}$*${UI_COLOR_RESET}"
}

ui_cyan_text() {
    printf '%b' "${UI_COLOR_CYAN}$*${UI_COLOR_RESET}"
}

ui_blue_text() {
    printf '%b' "${UI_COLOR_BLUE}$*${UI_COLOR_RESET}"
}

ui_magenta_text() {
    printf '%b' "${UI_COLOR_MAGENTA}$*${UI_COLOR_RESET}"
}

ui_red_bg_text() {
    printf '%b' "${UI_COLOR_RED_BG}$*${UI_COLOR_RESET}"
}

ui_init_colors

is_sh_owner=ExNG51
# github=https://github.com/ExNG51/sing-box

msg() { ui_print "$@"; }
_red() { ui_red_text "$@"; }
_blue() { ui_blue_text "$@"; }
_cyan() { ui_cyan_text "$@"; }
_green() { ui_green_text "$@"; }
_yellow() { ui_yellow_text "$@"; }
_magenta() { ui_magenta_text "$@"; }
_red_bg() { ui_red_bg_text "$@"; }

_legacy_helper_warn() {
    if type backup_warn >/dev/null 2>&1; then
        backup_warn "$*"
    elif type warn >/dev/null 2>&1; then
        warn "$*"
    else
        printf 'WARN: %s\n' "$*" >&2
    fi
}

_rm() {
    if type safe_remove_path >/dev/null 2>&1; then
        safe_remove_path "$@"
        return
    fi
    _legacy_helper_warn "safe_remove_path unavailable; refusing _rm."
    return 1
}
_cp() {
    local src dst

    [[ $# -eq 2 ]] || {
        _legacy_helper_warn "_cp only supports one source and one destination through safe operations."
        return 1
    }
    type safe_copy_file >/dev/null 2>&1 || {
        _legacy_helper_warn "safe_copy_file unavailable; refusing _cp."
        return 1
    }
    src=$1
    dst=$2
    if [[ -d $src ]]; then
        type safe_copy_contents >/dev/null 2>&1 || {
            _legacy_helper_warn "safe_copy_contents unavailable; refusing directory _cp."
            return 1
        }
        safe_copy_contents "$src" "$dst"
    else
        safe_copy_file "$src" "$dst"
    fi
}
_sed() {
    local expression path

    [[ $# -eq 2 ]] || {
        _legacy_helper_warn "_sed only supports: _sed <expression> <path>."
        return 1
    }
    type safe_sed_inplace >/dev/null 2>&1 || {
        _legacy_helper_warn "safe_sed_inplace unavailable; refusing _sed."
        return 1
    }
    expression=$1
    path=$2
    safe_sed_inplace "$path" "$expression"
}
_mkdir() {
    local path

    [[ $# -gt 0 ]] || {
        _legacy_helper_warn "refusing _mkdir with no paths."
        return 1
    }
    type safe_ensure_dir >/dev/null 2>&1 || {
        _legacy_helper_warn "safe_ensure_dir unavailable; refusing _mkdir."
        return 1
    }
    for path in "$@"; do
        safe_ensure_dir "$path" || return 1
    done
}

is_err=$(_red_bg 错误!)
is_warn=$(_red_bg 警告!)

err() {
    printf '\n' >&2
    ui_error "$is_err $*"
    printf '\n' >&2
    [[ ${is_dont_auto_exit:-} ]] && return 1
    exit 1
}

warn() {
    printf '\n' >&2
    ui_warn "$is_warn $*"
    printf '\n' >&2
}

# load bash script.
load() {
    . $is_sh_dir/src/$1
}

# wget wrapper. TLS certificate verification is enabled by default.
_wget() {
    # [[ $proxy ]] && export https_proxy=$proxy
    local wget_opts=()
    [[ ${SING_BOX_INSECURE_DOWNLOAD:-} ]] && wget_opts+=("--no-check-certificate")
    wget "${wget_opts[@]}" "$@"
}

# apt-get, yum, zypper or apk
cmd=$(type -P apt-get || type -P yum || type -P zypper || type -P apk)

# x64
case $(uname -m) in
amd64 | x86_64)
    is_arch="amd64"
    ;;
*aarch64* | *armv8*)
    is_arch="arm64"
    ;;
*)
    err "此脚本仅支持 64 位系统..."
    ;;
esac

is_core=sing-box
is_core_name=sing-box
is_core_dir=/etc/$is_core
is_core_bin=$is_core_dir/bin/$is_core
is_core_repo=SagerNet/$is_core
is_conf_dir=$is_core_dir/conf
is_log_dir=/var/log/$is_core
is_sh_bin=/usr/local/bin/$is_core
is_shell_profile=/root/.bashrc
is_sh_dir=$is_core_dir/sh
is_sh_repo=$is_sh_owner/$is_core
is_pkg="wget unzip tar qrencode bash ca-certificates coreutils"
is_config_json=$is_core_dir/config.json
is_caddy_bin=/usr/local/bin/caddy
is_caddy_dir=/etc/caddy
is_caddy_repo=caddyserver/caddy
is_caddyfile=$is_caddy_dir/Caddyfile
is_caddy_conf=$is_caddy_dir/$is_core
is_systemd=$(type -P systemctl)
is_openrc=$(type -P rc-service)
if [[ $is_systemd ]]; then
    is_caddy_service=$(systemctl list-units --full -all | grep caddy.service)
elif [[ $is_openrc ]]; then
    [[ -f /etc/init.d/caddy ]] && is_caddy_service=1
fi
is_http_port=80
is_https_port=443

# core ver
is_core_ver=$($is_core_bin version | head -n1 | cut -d " " -f3)

# tmp tls key
is_tls_cer=$is_core_dir/bin/tls.cer
is_tls_key=$is_core_dir/bin/tls.key
[[ ! -f $is_tls_cer || ! -f $is_tls_key ]] && {
    is_tls_tmp=${is_tls_key/key/tmp}
    $is_core_bin generate tls-keypair tls -m 456 >$is_tls_tmp
    awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' $is_tls_tmp >$is_tls_key
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' $is_tls_tmp >$is_tls_cer
    rm $is_tls_tmp
}

if [[ $(pgrep -f $is_core_bin 2>/dev/null || grep -l "$is_core_bin" /proc/*/cmdline 2>/dev/null) ]]; then
    is_core_status=$(_green running)
else
    is_core_status=$(_red_bg stopped)
    is_core_stop=1
fi
if [[ -f $is_caddy_bin && -d $is_caddy_dir && $is_caddy_service ]]; then
    is_caddy=1
    if [[ $is_systemd ]]; then
        [[ -f /lib/systemd/system/caddy.service && ! $(grep '\-\-adapter caddyfile' /lib/systemd/system/caddy.service) ]] && {
            load systemd.sh
            install_service caddy
            systemctl restart caddy &
        }
    fi
    is_caddy_ver=$($is_caddy_bin version | head -n1 | cut -d " " -f1)
    is_tmp_http_port=$(grep -E '^ {2,}http_port|^http_port' $is_caddyfile | grep -E -o [0-9]+)
    is_tmp_https_port=$(grep -E '^ {2,}https_port|^https_port' $is_caddyfile | grep -E -o [0-9]+)
    [[ $is_tmp_http_port ]] && is_http_port=$is_tmp_http_port
    [[ $is_tmp_https_port ]] && is_https_port=$is_tmp_https_port
    if [[ $(pgrep -f $is_caddy_bin 2>/dev/null || grep -l "$is_caddy_bin" /proc/*/cmdline 2>/dev/null) ]]; then
        is_caddy_status=$(_green running)
    else
        is_caddy_status=$(_red_bg stopped)
        is_caddy_stop=1
    fi
fi

load version.sh
load backup.sh
load core.sh
[[ ! $args ]] && args=main
main $args
