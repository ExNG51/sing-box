#!/bin/bash

is_sh_owner=ExNG51
# github=https://github.com/ExNG51/sing-box

# bash fonts colors
red='\e[31m'
yellow='\e[33m'
# Used by sourced scripts.
# shellcheck disable=SC2034
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'
# Used by sourced scripts.
# shellcheck disable=SC2329
_red() { echo -e "${red}$*${none}"; }
# shellcheck disable=SC2329
_blue() { echo -e "${blue}$*${none}"; }
# shellcheck disable=SC2329
_cyan() { echo -e "${cyan}$*${none}"; }
# shellcheck disable=SC2329
_green() { echo -e "${green}$*${none}"; }
# shellcheck disable=SC2329
_yellow() { echo -e "${yellow}$*${none}"; }
# shellcheck disable=SC2329
_magenta() { echo -e "${magenta}$*${none}"; }
_red_bg() { echo -e "\e[41m$*${none}"; }

is_err=$(_red_bg 错误!)
is_warn=$(_red_bg 警告!)

err() {
    echo -e "\n$is_err $*\n" && exit 1
}

warn() {
    echo -e "\n$is_warn $*\n"
}

IS_DRY_RUN=false
IS_ASSUME_YES=false
PLAN_ITEMS=()

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
is_pkg="wget tar bash ca-certificates coreutils"
is_config_json=$is_core_dir/config.json
tmp_var_lists=(
    tmpcore
    tmpsh
    tmpjq
    is_core_ok
    is_sh_ok
    is_jq_ok
    is_pkg_ok
)
tmpdir=
tmpcore=
tmpsh=
tmpjq=
is_core_ok=
is_sh_ok=
is_jq_ok=
is_pkg_ok=
is_install_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)

prepare_tmpdir() {
    [[ $tmpdir ]] && return
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sing-box-install.XXXXXX") || err "创建临时目录失败."
    trap 'rm -rf "$tmpdir"' EXIT INT TERM
    for i in "${tmp_var_lists[@]}"; do
        export "$i=$tmpdir/$i"
    done
}

detect_os_name() {
    local os_release=${OS_RELEASE_FILE:-/etc/os-release}
    if [[ -r $os_release ]]; then
        # shellcheck disable=SC1090
        . "$os_release"
        is_os_name=${PRETTY_NAME:-${NAME:-Unknown}}
    else
        is_os_name=$(uname -s)
    fi
}

detect_install_environment() {
    detect_os_name

    cmd=$(type -P apt-get || type -P yum || type -P zypper || type -P apk)
    [[ ! $cmd ]] && err "此脚本仅支持 ${yellow}(Ubuntu or Debian or CentOS or SUSE or Alpine)${none}."
    is_package_manager=$(basename "$cmd")

    is_systemd=$(type -P systemctl)
    is_openrc=$(type -P rc-service)
    [[ ! $is_systemd && ! $is_openrc ]] && {
        err "此系统缺少 ${yellow}(systemctl 或 rc-service)${none}, 请安装 systemd 或确认 OpenRC 已启用."
    }
    if [[ $is_systemd ]]; then
        is_init_system=systemd
    else
        is_init_system=openrc
    fi

    is_wget=$(type -P wget)

    case $(uname -m) in
    amd64 | x86_64)
        is_arch=amd64
        ;;
    *aarch64* | *armv8*)
        is_arch=arm64
        ;;
    *)
        err "此脚本仅支持 64 位系统..."
        ;;
    esac

    is_pkg="wget tar bash ca-certificates coreutils"
    # Alpine: gcompat provides glibc compatibility for prebuilt binaries
    [[ $cmd =~ apk ]] && is_pkg="$is_pkg gcompat jq"
}

ensure_root_for_execution() {
    [[ $EUID != 0 ]] && err "当前非 ${yellow}ROOT用户.${none}"
}

ensure_not_installed() {
    [[ -f $is_sh_bin && -d $is_core_dir/bin && -d $is_sh_dir && -d $is_conf_dir ]] && {
        err "检测到脚本已安装, 如需重装请使用${green} ${is_core} reinstall ${none}命令."
    }
}

# load bash script.
load() {
    # shellcheck disable=SC1090
    . "$is_sh_dir/src/$1"
}

load_install_support_script() {
    local script=$1
    local member
    local support_dir
    if [[ -f $PWD/src/$script ]]; then
        # shellcheck disable=SC1090
        . "$PWD/src/$script"
        return
    fi
    if [[ -n ${is_sh_ok:-} && -f $is_sh_ok ]]; then
        support_dir=$tmpdir/install-support
        mkdir -p "$support_dir"
        for member in "src/$script" "./src/$script"; do
            tar zxf "$is_sh_ok" -C "$support_dir" "$member" 2>/dev/null || true
            if [[ -f $support_dir/src/$script ]]; then
                # shellcheck disable=SC1090
                . "$support_dir/src/$script"
                return
            fi
        done
    fi
    err "无法加载安装支持脚本: src/$script"
}

ensure_backup_functions_loaded() {
    type safe_write_file >/dev/null 2>&1 && return
    load_install_support_script backup.sh
}

load_install_version_policy() {
    if [[ -f $is_install_script_dir/src/version.sh ]]; then
        # shellcheck disable=SC1090
        . "$is_install_script_dir/src/version.sh"
    elif [[ -f $PWD/src/version.sh ]]; then
        # shellcheck disable=SC1090
        . "$PWD/src/version.sh"
    else
        DEFAULT_SING_BOX_STABLE_VERSION=${DEFAULT_SING_BOX_STABLE_VERSION:-v1.13.8}
        IS_USE_LATEST_VERSION=${IS_USE_LATEST_VERSION:-false}
        IS_USER_CORE_VERSION_SPECIFIED=${IS_USER_CORE_VERSION_SPECIFIED:-false}
    fi
}

install_normalize_core_version() {
    if type normalize_core_version >/dev/null 2>&1; then
        normalize_core_version "$1"
    else
        printf 'v%s' "${1#v}"
    fi
}

apply_install_core_version_policy() {
    [[ $is_core_file ]] && return
    if [[ $IS_USER_CORE_VERSION_SPECIFIED == true ]]; then
        is_core_ver=$(install_normalize_core_version "$is_core_ver")
        echo "Using user-specified sing-box version: $is_core_ver"
    elif [[ $IS_USE_LATEST_VERSION == true ]]; then
        echo "Using latest sing-box release. This may introduce breaking changes."
    else
        is_core_ver=$DEFAULT_SING_BOX_STABLE_VERSION
        echo "Using pinned stable sing-box version: $is_core_ver"
    fi
}

load_install_version_policy

# wget wrapper. TLS certificate verification is enabled by default.
_wget() {
    local wget_opts=()
    [[ $proxy ]] && export https_proxy=$proxy
    [[ $insecure_download ]] && wget_opts+=("--no-check-certificate")
    wget "${wget_opts[@]}" "$@"
}

verify_https_url() {
    case $1 in
    https://*) ;;
    *) err "拒绝非 HTTPS 下载地址: $1" ;;
    esac
}

download_to_file() {
    local url=$1
    local output=$2
    verify_https_url "$url"
    _wget -t 3 -q -O "$output" "$url"
}

verify_sha256() {
    local file=$1
    local expected=${2#sha256:}
    local actual
    [[ -f $file ]] || err "无法校验不存在的文件: $file"
    [[ $expected ]] || err "缺少 SHA256 校验值: $file"
    if type -P sha256sum >/dev/null; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif type -P shasum >/dev/null; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        err "缺少 sha256sum 或 shasum, 无法校验下载文件."
    fi
    [[ $actual == "$expected" ]] || err "SHA256 校验失败: $file"
}

get_github_asset_digest() {
    local repo=$1
    local tag=$2
    local asset=$3
    local api json_file digest
    if [[ $tag == "latest" ]]; then
        api="https://api.github.com/repos/${repo}/releases/latest?v=$RANDOM"
    else
        api="https://api.github.com/repos/${repo}/releases/tags/${tag}?v=$RANDOM"
    fi
    json_file="$tmpdir/github-${repo//\//-}-${tag}.json"
    download_to_file "$api" "$json_file" || return 1
    digest=$(awk -v asset="$asset" '
        /"name":/ {
            name=$0
            sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", name)
            sub(/".*$/, "", name)
        }
        /"digest":/ {
            digest=$0
            sub(/^.*"digest"[[:space:]]*:[[:space:]]*"/, "", digest)
            sub(/".*$/, "", digest)
            if (name == asset && digest != "null") {
                print digest
                exit
            }
        }
    ' "$json_file")
    [[ $digest ]] || err "无法获取 ${repo} ${tag} ${asset} 的 SHA256 digest."
    echo "$digest"
}

get_release_checksum_sha256() {
    local checksum_url=$1
    local asset=$2
    local checksum_file=$3
    local digest
    download_to_file "$checksum_url" "$checksum_file" || return 1
    digest=$(awk -v asset="$asset" '($2 == asset || $2 == "*" asset) { print $1; exit }' "$checksum_file")
    [[ $digest ]] || err "无法在 checksum 文件中找到: $asset"
    echo "$digest"
}

# print a mesage
msg() {
    case $1 in
    warn)
        local color=$yellow
        ;;
    err)
        local color=$red
        ;;
    ok)
        local color=$green
        ;;
    esac

    echo -e "${color}$(date +'%T')${none}) ${2}"
}

add_plan_item() {
    local section=$1
    shift
    PLAN_ITEMS+=("${section}|$*")
}

print_plan_section() {
    local section=$1
    local item item_section item_text
    echo "$section:"
    for item in "${PLAN_ITEMS[@]}"; do
        item_section=${item%%|*}
        item_text=${item#*|}
        [[ $item_section == "$section" ]] && echo "- $item_text"
    done
    echo
}

build_install_plan() {
    PLAN_ITEMS=()

    add_plan_item "System" "OS: ${is_os_name:-Unknown}"
    add_plan_item "System" "Arch: ${is_arch:-unknown}"
    add_plan_item "System" "Init: ${is_init_system:-unknown}"
    add_plan_item "System" "Package manager: ${is_package_manager:-unknown}"

    if [[ $is_core_file ]]; then
        add_plan_item "Downloads" "sing-box core package from local file: $is_core_file"
    elif [[ ${IS_USE_LATEST_VERSION:-false} == true ]]; then
        add_plan_item "Downloads" "sing-box core package from GitHub latest release: https://github.com/${is_core_repo}/releases"
        add_plan_item "Downloads" "release version will be resolved during execution because --latest was specified"
    elif [[ $is_core_ver ]]; then
        add_plan_item "Downloads" "sing-box core package from GitHub release $is_core_ver: https://github.com/${is_core_repo}/releases"
    else
        add_plan_item "Downloads" "sing-box core package from pinned stable release $DEFAULT_SING_BOX_STABLE_VERSION: https://github.com/${is_core_repo}/releases"
    fi
    if [[ $local_install ]]; then
        add_plan_item "Downloads" "management script from local directory: $PWD"
    else
        add_plan_item "Downloads" "management script package from GitHub release: https://github.com/${is_sh_repo}/releases"
    fi
    add_plan_item "Downloads" "jq binary from GitHub release if jq is still unavailable after dependency installation"
    add_plan_item "Downloads" "checksum / digest source: GitHub release asset digest and jq sha256sum.txt"
    add_plan_item "Downloads" "download source: HTTPS-only GitHub release URLs"
    add_plan_item "Downloads" "temp directory: ${tmpdir:-${TMPDIR:-/tmp}/sing-box-install.xxxxxx}"

    add_plan_item "Files to write" "$is_core_dir/"
    add_plan_item "Files to write" "$is_core_dir/bin/$is_core"
    add_plan_item "Files to write" "$is_sh_dir/"
    add_plan_item "Files to write" "$is_conf_dir/"
    add_plan_item "Files to write" "$is_config_json"
    add_plan_item "Files to write" "$is_log_dir/"
    add_plan_item "Files to write" "$is_sh_bin"
    add_plan_item "Files to write" "${is_sh_bin/$is_core/sb}"
    add_plan_item "Files to write" "$is_shell_profile"
    add_plan_item "Files to write" "/usr/bin/jq when jq is not already installed"
    if [[ $is_init_system == systemd ]]; then
        add_plan_item "Files to write" "/etc/systemd/system/$is_core.service"
        add_plan_item "Files to write" "/lib/systemd/system/$is_core.service"
        add_plan_item "Services" "create: $is_core.service"
        add_plan_item "Services" "enable: $is_core.service"
        add_plan_item "Services" "start: $is_core.service"
    else
        add_plan_item "Files to write" "/etc/init.d/$is_core"
        add_plan_item "Services" "create: /etc/init.d/$is_core"
        add_plan_item "Services" "add to default runlevel"
        add_plan_item "Services" "start: $is_core"
    fi

    add_plan_item "Ports" "none by default"
    add_plan_item "Ports" "protocol ports will be opened only after user explicitly adds an inbound from the menu"
}

print_install_plan() {
    echo "Install Plan"
    echo
    print_plan_section "System"
    print_plan_section "Downloads"
    print_plan_section "Files to write"
    print_plan_section "Services"
    print_plan_section "Ports"
}

confirm_install_plan() {
    local reply
    [[ $IS_ASSUME_YES == true ]] && return 0
    printf "Continue with this installation plan? [y/N] "
    read -r reply || reply=
    case $reply in
    y | Y)
        return 0
        ;;
    *)
        msg warn "Installation cancelled."
        exit_and_del_tmpdir ok
        ;;
    esac
}

run_or_plan() {
    local description=$1
    shift
    if [[ $IS_DRY_RUN == true ]]; then
        add_plan_item "Execution" "$description"
        return 0
    fi
    "$@"
}

write_or_plan_file() {
    local path=$1
    shift
    if [[ $IS_DRY_RUN == true ]]; then
        add_plan_item "Files to write" "$path"
        return 0
    fi
    "$@"
}

download_or_plan_asset() {
    local description=$1
    shift
    if [[ $IS_DRY_RUN == true ]]; then
        add_plan_item "Downloads" "$description"
        return 0
    fi
    download "$@"
}

# show help msg
show_help() {
    echo -e "Usage: $0 [-f xxx | -l | -p xxx | -v xxx | --latest | --dry-run | --plan | --yes | -h]"
    echo -e "  -f, --core-file <path>          自定义 $is_core_name 文件路径, e.g., -f /root/$is_core-linux-amd64.tar.gz"
    echo -e "  -l, --local-install             本地获取安装脚本, 使用当前目录"
    echo -e "  -p, --proxy <addr>              使用代理下载, e.g., -p http://127.0.0.1:2333"
    echo -e "  -v, --core-version <ver>        自定义 $is_core_name 版本, e.g., -v v1.13.8"
    echo -e "      --latest                    显式使用最新 $is_core_name release; 默认使用 pinned stable ($DEFAULT_SING_BOX_STABLE_VERSION)"
    echo -e "      --dry-run                   仅输出安装计划, 不修改系统"
    echo -e "      --plan                      等同于 --dry-run"
    echo -e "      --yes                       跳过安装计划确认, 适用于自动化"
    echo -e "      --insecure-download         禁用 TLS 证书校验下载, 仅用于受限网络; 仍会校验 SHA256"
    echo -e "  -h, --help                      显示此帮助界面\n"

    exit 0
}

# install dependent pkg
install_pkg() {
    cmd_not_found=
    for i in "$@"; do
        [[ ! $(type -P "$i") ]] && cmd_not_found="$cmd_not_found,$i"
    done
    if [[ $cmd_not_found ]]; then
        pkg=${cmd_not_found//,/ }
        msg warn "安装依赖包 >${pkg}"
        if [[ $cmd =~ apk ]]; then
            apk update &>/dev/null
            # shellcheck disable=SC2086
            apk add $pkg &>/dev/null && : >"$is_pkg_ok"
        else
            # shellcheck disable=SC2086
            if ! $cmd install -y $pkg &>/dev/null; then
                [[ $cmd =~ yum ]] && yum install epel-release -y &>/dev/null
                if [[ $cmd =~ zypper ]]; then
                    $cmd --non-interactive refresh &>/dev/null
                else
                    $cmd update -y &>/dev/null
                fi
                # shellcheck disable=SC2086
                $cmd install -y $pkg &>/dev/null && : >"$is_pkg_ok"
            else
                : >"$is_pkg_ok"
            fi
        fi
    else
        : >"$is_pkg_ok"
    fi
}

# download file
download() {
    case $1 in
    core)
        if [[ ! $is_core_ver ]]; then
            if [[ ${IS_USE_LATEST_VERSION:-false} == true ]]; then
                is_core_ver=$(_wget -qO- "https://api.github.com/repos/${is_core_repo}/releases/latest?v=$RANDOM" | grep tag_name | grep -E -o 'v([0-9.]+)')
            else
                is_core_ver=$DEFAULT_SING_BOX_STABLE_VERSION
            fi
        fi
        asset="${is_core}-${is_core_ver:1}-linux-${is_arch}.tar.gz"
        [[ $is_core_ver ]] && link="https://github.com/${is_core_repo}/releases/download/${is_core_ver}/${asset}"
        digest=$(get_github_asset_digest "$is_core_repo" "$is_core_ver" "$asset")
        name=$is_core_name
        tmpfile=$tmpcore
        is_ok=$is_core_ok
        ;;
    sh)
        asset=code.tar.gz
        is_sh_latest_ver=$(_wget -qO- "https://api.github.com/repos/${is_sh_repo}/releases/latest?v=$RANDOM" | grep tag_name | grep -E -o 'v([0-9.]+)')
        [[ $is_sh_latest_ver ]] || err "获取 ${is_core_name} 脚本最新版本失败."
        link=https://github.com/${is_sh_repo}/releases/download/${is_sh_latest_ver}/${asset}
        digest=$(get_github_asset_digest "$is_sh_repo" "$is_sh_latest_ver" "$asset")
        name="$is_core_name 脚本"
        tmpfile=$tmpsh
        is_ok=$is_sh_ok
        ;;
    jq)
        asset=jq-linux-$is_arch
        link=https://github.com/jqlang/jq/releases/download/jq-1.7.1/$asset
        digest=$(get_release_checksum_sha256 "https://github.com/jqlang/jq/releases/download/jq-1.7.1/sha256sum.txt" "$asset" "$tmpdir/jq-sha256sum.txt")
        name="jq"
        tmpfile=$tmpjq
        is_ok=$is_jq_ok
        ;;
    esac

    [[ $link ]] && {
        msg warn "下载 ${name} > ${link}"
        if download_to_file "$link" "$tmpfile"; then
            verify_sha256 "$tmpfile" "$digest"
            mv -f "$tmpfile" "$is_ok"
        fi
    }
}

# get server ip
get_ip() {
    export "$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace | grep ip=)" &>/dev/null
    [[ -z $ip ]] && export "$(_wget -6 -qO- https://one.one.one.one/cdn-cgi/trace | grep ip=)" &>/dev/null
}

# check background tasks status
check_status() {
    # dependent pkg install fail
    [[ ! -f $is_pkg_ok ]] && {
        msg err "安装依赖包失败"
        if [[ $cmd =~ apk ]]; then
            msg err "请尝试手动安装依赖包: apk update; apk add $is_pkg"
        else
            msg err "请尝试手动安装依赖包: $cmd update -y; $cmd install -y $is_pkg"
        fi
        is_fail=1
    }

    # download file status
    if [[ $is_wget ]]; then
        [[ ! -f $is_core_ok ]] && {
            msg err "下载 ${is_core_name} 失败"
            is_fail=1
        }
        [[ ! -f $is_sh_ok ]] && {
            msg err "下载 ${is_core_name} 脚本失败"
            is_fail=1
        }
        [[ ! -f $is_jq_ok ]] && {
            msg err "下载 jq 失败"
            is_fail=1
        }
    else
        [[ ! $is_fail ]] && {
            is_wget=1
            [[ ! $is_core_file ]] && download core &
            [[ ! $local_install ]] && download sh &
            [[ $jq_not_found ]] && download jq &
            get_ip
            wait
            check_status
        }
    fi

    # found fail status, remove tmp dir and exit.
    [[ $is_fail ]] && {
        exit_and_del_tmpdir
    }
}

# parameters check
pass_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        -f | --core-file)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 /root/$is_core-linux-amd64.tar.gz]"
            } || [[ ! -f $2 ]] && {
                err "($2) 不是一个常规的文件."
            }
            is_core_file=$2
            shift 2
            ;;
        -l | --local-install)
            [[ ! -f ${PWD}/src/core.sh || ! -f ${PWD}/$is_core.sh ]] && {
                err "当前目录 (${PWD}) 非完整的脚本目录."
            }
            local_install=1
            shift 1
            ;;
        -p | --proxy)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 http://127.0.0.1:2333 or -p socks5://127.0.0.1:2333]"
            }
            proxy=$2
            shift 2
            ;;
        -v | --core-version)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 v1.13.8]"
            }
            is_core_ver=$(install_normalize_core_version "$2")
            IS_USER_CORE_VERSION_SPECIFIED=true
            shift 2
            ;;
        --latest)
            IS_USE_LATEST_VERSION=true
            shift 1
            ;;
        --insecure-download)
            insecure_download=1
            warn "已启用不安全下载模式: TLS 证书校验被禁用, 但下载文件仍会执行 SHA256 校验."
            shift 1
            ;;
        --dry-run | --plan)
            IS_DRY_RUN=true
            shift 1
            ;;
        --yes)
            IS_ASSUME_YES=true
            shift 1
            ;;
        -h | --help)
            show_help
            ;;
        *)
            echo -e "\n${is_err} ($*) 为未知参数...\n"
            show_help
            ;;
        esac
    done
    [[ $is_core_ver && $is_core_file ]] && {
        err "无法同时自定义 ${is_core_name} 版本和 ${is_core_name} 文件."
    }
    [[ $IS_USE_LATEST_VERSION == true && $IS_USER_CORE_VERSION_SPECIFIED == true ]] && {
        err "Cannot use --latest and --core-version at the same time."
    }
    [[ $IS_USE_LATEST_VERSION == true && $is_core_file ]] && {
        err "无法同时使用 --latest 和自定义 ${is_core_name} 文件."
    }
}

# exit and remove tmpdir
exit_and_del_tmpdir() {
    [[ ${tmpdir:-} ]] && rm -rf "$tmpdir"
    [[ ! ${1:-} ]] && {
        msg err "哦豁.."
        msg err "安装过程出现错误..."
        echo -e "反馈问题) https://github.com/${is_sh_repo}/issues"
        echo
        exit 1
    }
    exit 0
}

show_install_complete() {
    msg ok "$is_core_name installed successfully."
    msg ok "No inbound protocol has been created by default."
    msg ok "No proxy protocol has been created automatically."
    msg ok "Use the menu to add AnyTLS, Reality, TUIC, Hysteria2, Trojan, Shadowsocks, VMess, or other supported protocols."
    msg ok "$is_core_name 已安装完成。"
    msg ok "当前未自动创建任何代理协议配置。"
    msg ok "请在主菜单中手动选择需要添加的协议，例如 AnyTLS、Reality、TUIC、Hysteria2、Trojan、Shadowsocks、VMess 等。"
}

open_main_menu_if_interactive() {
    if [ -t 0 ] && [ -t 1 ]; then
        "$is_sh_bin" main
    else
        msg ok "Run '$is_core' or 'sb' to open the menu and add a protocol."
    fi
}

execute_install() {
    # start installing...
    msg warn "开始安装..."
    [[ $is_core_ver ]] && msg warn "${is_core_name} 版本: ${yellow}$is_core_ver${none}"
    [[ $proxy ]] && msg warn "使用代理: ${yellow}$proxy${none}"
    # create tmpdir
    run_or_plan "create temp directory $tmpdir" mkdir -p "$tmpdir"
    # if is_core_file, copy file
    [[ $is_core_file ]] && {
        write_or_plan_file "$is_core_ok" cp -f "$is_core_file" "$is_core_ok"
        msg warn "${yellow}${is_core_name} 文件使用 > $is_core_file${none}"
    }
    # local dir install sh script
    [[ $local_install ]] && {
        : >"$is_sh_ok"
        msg warn "${yellow}本地获取安装脚本 > $PWD ${none}"
    }

    if [[ $is_systemd ]]; then
        if ! timedatectl set-ntp true &>/dev/null; then
            # Used by src/core.sh after it is sourced.
            # shellcheck disable=SC2034
            is_ntp_on=1
        fi
    fi

    # install dependent pkg
    if [[ $cmd =~ apk ]]; then
        # Alpine: force install full versions to replace BusyBox applets
        apk update &>/dev/null
        # shellcheck disable=SC2086
        apk add $is_pkg &>/dev/null && : >"$is_pkg_ok"
    else
        # shellcheck disable=SC2086
        install_pkg $is_pkg
    fi
    is_wget=$(type -P wget)
    if type -P update-ca-certificates >/dev/null; then
        update-ca-certificates &>/dev/null || true
    fi

    # jq
    if [[ $(type -P jq) ]]; then
        : >"$is_jq_ok"
    else
        jq_not_found=1
    fi
    # if wget installed. download core, sh, jq, get ip
    [[ $is_wget ]] && {
        [[ ! $is_core_file ]] && download_or_plan_asset "sing-box core package" core &
        [[ ! $local_install ]] && download_or_plan_asset "management script package" sh &
        [[ $jq_not_found ]] && download_or_plan_asset "jq binary" jq &
        get_ip
    }

    # waiting for background tasks is done
    wait

    # check background tasks status
    check_status

    # test $is_core_file
    if [[ $is_core_file ]]; then
        mkdir -p "$tmpdir/testzip"
        if ! tar zxf "$is_core_ok" --strip-components 1 -C "$tmpdir/testzip" &>/dev/null; then
            msg err "${is_core_name} 文件无法通过测试."
            exit_and_del_tmpdir
        fi
        [[ ! -f $tmpdir/testzip/$is_core ]] && {
            msg err "${is_core_name} 文件无法通过测试."
            exit_and_del_tmpdir
        }
    fi

    # get server ip.
    [[ ! $ip ]] && {
        msg err "获取服务器 IP 失败."
        exit_and_del_tmpdir
    }

    ensure_backup_functions_loaded
    init_backup_transaction install

    # create sh dir...
    write_or_plan_file "$is_sh_dir/" safe_ensure_dir "$is_sh_dir"

    # copy sh file or unzip sh zip file.
    if [[ $local_install ]]; then
        write_or_plan_file "$is_sh_dir/" safe_copy_contents "$PWD" "$is_sh_dir"
    else
        write_or_plan_file "$is_sh_dir/" backup_path_before_write "$is_sh_dir"
        write_or_plan_file "$is_sh_dir/" tar zxf "$is_sh_ok" -C "$is_sh_dir"
    fi

    # create core bin dir
    write_or_plan_file "$is_core_dir/bin/" safe_ensure_dir "$is_core_dir/bin"
    # copy core file or unzip core zip file
    if [[ $is_core_file ]]; then
        write_or_plan_file "$is_core_dir/bin/$is_core" safe_copy_contents "$tmpdir/testzip" "$is_core_dir/bin"
    else
        write_or_plan_file "$is_core_dir/bin/$is_core" backup_path_before_write "$is_core_bin"
        write_or_plan_file "$is_core_dir/bin/$is_core" tar zxf "$is_core_ok" --strip-components 1 -C "$is_core_dir/bin"
    fi

    # add aliases
    write_or_plan_file "$is_shell_profile" safe_update_shell_aliases "$is_shell_profile"

    # core command
    write_or_plan_file "$is_sh_bin" safe_link_file "$is_sh_dir/$is_core.sh" "$is_sh_bin"
    write_or_plan_file "${is_sh_bin/$is_core/sb}" safe_link_file "$is_sh_dir/$is_core.sh" "${is_sh_bin/$is_core/sb}"

    # jq
    [[ $jq_not_found ]] && write_or_plan_file "/usr/bin/jq" safe_copy_file "$is_jq_ok" /usr/bin/jq

    # chmod
    safe_chmod_path +x "$is_core_bin"
    [[ -e /usr/bin/jq ]] && chmod +x /usr/bin/jq

    # create log dir
    write_or_plan_file "$is_log_dir/" safe_ensure_dir "$is_log_dir"

    # show a tips msg
    msg ok "生成配置文件..."

    # create service
    load systemd.sh
    # Used by src/core.sh after it is sourced.
    # shellcheck disable=SC2034
    is_new_install=1
    install_service $is_core &>/dev/null

    # create condf dir
    safe_ensure_dir "$is_conf_dir"

    load core.sh
    # create the base config only; protocol configs are added from the menu.
    create config.json
    # wait for background tasks (e.g., OpenRC service start)
    wait
    finalize_backup_transaction
    show_install_complete
    open_main_menu_if_interactive
    # remove tmp dir and exit.
    exit_and_del_tmpdir ok
}

# main
main() {
    # check parameters
    [[ $# -gt 0 ]] && pass_args "$@"

    apply_install_core_version_policy
    detect_install_environment
    build_install_plan

    # show welcome msg
    [[ -t 1 ]] && clear
    echo
    echo "........... $is_core_name script .........."
    echo
    print_install_plan

    [[ $IS_DRY_RUN == true ]] && exit_and_del_tmpdir ok

    confirm_install_plan
    ensure_root_for_execution
    ensure_not_installed
    prepare_tmpdir
    execute_install
}

# start.
main "$@"
