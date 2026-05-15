#!/bin/bash

protocol_list=(
    TUIC
    Trojan
    Hysteria2
    VMess-WS
    VMess-TCP
    VMess-HTTP
    VMess-QUIC
    Shadowsocks
    VMess-H2-TLS
    VMess-WS-TLS
    VLESS-H2-TLS
    VLESS-WS-TLS
    Trojan-H2-TLS
    Trojan-WS-TLS
    VMess-HTTPUpgrade-TLS
    VLESS-HTTPUpgrade-TLS
    Trojan-HTTPUpgrade-TLS
    VLESS-REALITY
    VLESS-HTTP2-REALITY
    AnyTLS
    # Direct
    Socks
)
ss_method_list=(
    aes-128-gcm
    aes-256-gcm
    chacha20-ietf-poly1305
    xchacha20-ietf-poly1305
    2022-blake3-aes-128-gcm
    2022-blake3-aes-256-gcm
    2022-blake3-chacha20-poly1305
)
mainmenu=(
    "添加配置"
    "更改配置"
    "查看配置"
    "删除配置"
    "运行管理"
    "更新"
    "卸载"
    "帮助"
    "其他"
    "关于"
)
info_list=(
    "协议 (protocol)"
    "地址 (address)"
    "端口 (port)"
    "用户ID (id)"
    "传输协议 (network)"
    "伪装类型 (type)"
    "伪装域名 (host)"
    "路径 (path)"
    "传输层安全 (TLS)"
    "应用层协议协商 (Alpn)"
    "密码 (password)"
    "加密方式 (encryption)"
    "链接 (URL)"
    "目标地址 (remote addr)"
    "目标端口 (remote port)"
    "流控 (flow)"
    "SNI (serverName)"
    "指纹 (Fingerprint)"
    "公钥 (Public key)"
    "用户名 (Username)"
    "跳过证书验证 (allowInsecure)"
    "拥塞控制算法 (congestion_control)"
)
change_list=(
    "更改协议"
    "更改端口"
    "更改域名"
    "更改路径"
    "更改密码"
    "更改 UUID"
    "更改加密方式"
    "更改目标地址"
    "更改目标端口"
    "更改密钥"
    "更改 SNI (serverName)"
    "更改伪装网站"
    "更改用户名 (Username)"
)
servername_list=(
    www.amazon.com
    www.ebay.com
    www.paypal.com
    www.cloudflare.com
    dash.cloudflare.com
    aws.amazon.com
)

# shuf fallback for systems without shuf (e.g., Alpine BusyBox)
if ! type -P shuf &>/dev/null; then
    shuf() {
        local min max n
        while [[ $# -gt 0 ]]; do
            case $1 in
            -i) IFS=- read min max <<<"$2"; shift 2 ;;
            -n) n=$2; shift 2 ;;
            -n*) n=${1#-n}; shift ;;
            *) shift ;;
            esac
        done
        echo $(( RANDOM % (max - min + 1) + min ))
    }
fi

is_random_ss_method=${ss_method_list[$(shuf -i 4-6 -n1)]} # random only use ss2022
is_random_servername=${servername_list[$(shuf -i 1-${#servername_list[@]} -n1) - 1]}

msg() { ui_print "$@"; }
msg_ul() { ui_print "${UI_STYLE_UNDERLINE:-}$*${UI_COLOR_RESET:-}"; }

# pause
pause() {
    ui_blank
    ui_print_inline "按 $(_green Enter 回车键) 继续, 或按 $(_red Ctrl + C) 取消."
    read -rs -d $'\n'
    ui_blank
}

get_uuid() {
    tmp_uuid=$(cat /proc/sys/kernel/random/uuid)
}

get_ip() {
    [[ $ip || $is_no_auto_tls || $is_gen || $is_dont_get_ip ]] && return
    export "$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace | grep ip=)" &>/dev/null
    [[ ! $ip ]] && export "$(_wget -6 -qO- https://one.one.one.one/cdn-cgi/trace | grep ip=)" &>/dev/null
    [[ ! $ip ]] && {
        err "获取服务器 IP 失败.."
    }
}

get_port() {
    is_count=0
    while :; do
        ((is_count++))
        if [[ $is_count -ge 233 ]]; then
            err "自动获取可用端口失败次数达到 233 次, 请检查端口占用情况."
        fi
        tmp_port=$(shuf -i 445-65535 -n 1)
        [[ ! $(is_test port_used $tmp_port) && $tmp_port != $port ]] && break
    done
}

get_pbk() {
    is_tmp_pbk=($($is_core_bin generate reality-keypair | sed 's/.*://'))
    is_public_key=${is_tmp_pbk[1]}
    is_private_key=${is_tmp_pbk[0]}
}

normalize_core_version() {
    printf '%s\n' "${1#v}" | sed -E 's/[^0-9.].*$//'
}

is_core_version_ge() {
    local current target
    local c_major c_minor c_patch
    local t_major t_minor t_patch

    current=$(normalize_core_version "${1:-$is_core_ver}")
    target=$(normalize_core_version "$2")
    [[ $current && $target ]] || return 1

    IFS=. read -r c_major c_minor c_patch _ <<<"$current"
    IFS=. read -r t_major t_minor t_patch _ <<<"$target"

    c_major=${c_major:-0}
    c_minor=${c_minor:-0}
    c_patch=${c_patch:-0}
    t_major=${t_major:-0}
    t_minor=${t_minor:-0}
    t_patch=${t_patch:-0}

    [[ $c_major =~ ^[0-9]+$ && $c_minor =~ ^[0-9]+$ && $c_patch =~ ^[0-9]+$ ]] || return 1
    [[ $t_major =~ ^[0-9]+$ && $t_minor =~ ^[0-9]+$ && $t_patch =~ ^[0-9]+$ ]] || return 1

    ((c_major > t_major)) && return 0
    ((c_major < t_major)) && return 1
    ((c_minor > t_minor)) && return 0
    ((c_minor < t_minor)) && return 1
    ((c_patch >= t_patch))
}

show_list() {
    local i=1
    local item

    for item in "$@"; do
        ui_menu_item "$i" "$item"
        i=$((i + 1))
    done
}

is_test() {
    case $1 in
    number)
        echo $2 | grep -E '^[1-9][0-9]*$'
        ;;
    port)
        if [[ $(is_test number $2) ]]; then
            [[ $2 -le 65535 ]] && echo ok
        fi
        ;;
    port_used)
        [[ $(is_port_used $2) && ! $is_cant_test_port ]] && echo ok
        ;;
    domain)
        echo $2 | grep -E -i '^\w(\w|\-|\.)?+\.\w+$'
        ;;
    path)
        echo $2 | grep -E -i '^\/\w(\w|\-|\/)?+\w$'
        ;;
    uuid)
        echo $2 | grep -E -i '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        ;;
    esac

}

is_port_used() {
    if [[ $(type -P netstat) ]]; then
        [[ ! $is_used_port ]] && is_used_port="$(netstat -tunlp | sed -n 's/.*:\([0-9]\+\).*/\1/p' | sort -nu)"
        echo $is_used_port | sed 's/ /\n/g' | grep ^${1}$
        return
    fi
    if [[ $(type -P ss) ]]; then
        [[ ! $is_used_port ]] && is_used_port="$(ss -tunlp | sed -n 's/.*:\([0-9]\+\).*/\1/p' | sort -nu)"
        echo $is_used_port | sed 's/ /\n/g' | grep ^${1}$
        return
    fi
    is_cant_test_port=1
    msg "$is_warn 无法检测端口是否可用."
    msg "请执行: $(_yellow "${cmd} update -y; ${cmd} install net-tools -y") 来修复此问题."
}

# cleanup ask globals after one prompt.
ask_cleanup() {
    unset is_opt_msg is_opt_input_msg is_tmp_list is_ask_result is_default_arg is_emtpy_exit
}

# ask input a string or pick a option for list.
ask() {
    local is_menu_back_option=
    local is_menu_exit_option=
    local is_prompt_min=1

    unset is_menu_back is_menu_exit
    case $1 in
    set_ss_method)
        is_tmp_list=(${ss_method_list[@]})
        is_default_arg=$is_random_ss_method
        is_opt_msg="\n请选择加密方式:\n"
        is_opt_input_msg="(默认\e[92m $is_default_arg\e[0m):"
        is_ask_set=ss_method
        ;;
    set_anytls_cert)
        is_tmp_list=("yes" "no")
        is_default_arg=yes
        is_opt_msg="\nAnyTLS 是否使用域名并启用 sing-box ACME 自动证书?\n\n脚本将写入 sing-box ACME 自动证书配置。\n证书由 sing-box 启动后申请和续期，不是脚本预先申请。\n继续前请确保域名 DNS only，且 TCP 443 已公网可达。\n"
        is_opt_input_msg="(默认\e[92m yes\e[0m):"
        is_ask_set=is_anytls_cert
        ;;
    set_protocol)
        is_tmp_list=(${protocol_list[@]})
        [[ $is_no_auto_tls ]] && {
            unset is_tmp_list
            for v in ${protocol_list[@]}; do
                [[ $(grep -i "\-tls$" <<<$v) ]] && is_tmp_list=(${is_tmp_list[@]} $v)
            done
        }
        is_opt_msg="\n请选择协议:\n"
        is_ask_set=is_new_protocol
        ;;
    set_change_list)
        is_tmp_list=()
        for v in ${is_can_change[@]}; do
            is_tmp_list+=("${change_list[$v]}")
        done
        is_opt_msg="\n请选择更改:\n"
        is_ask_set=is_change_str
        is_opt_input_msg=$3
        ;;
    string)
        is_ask_set=$2
        is_opt_input_msg=$3
        ;;
    list)
        is_ask_set=$2
        [[ ! ${is_tmp_list:-} ]] && is_tmp_list=($3)
        is_opt_msg=${4:-}
        is_opt_input_msg=${5:-}
        ;;
    get_config_file)
        is_tmp_list=("${is_all_json[@]}")
        is_opt_msg="\n请选择配置:\n"
        is_ask_set=is_config_file
        ;;
    mainmenu)
        is_tmp_list=("${mainmenu[@]}")
        is_ask_set=is_main_pick
        is_emtpy_exit=1
        is_menu_exit_option=1
        ;;
    esac

    [[ $is_main_start && ${is_tmp_list:-} && ! $is_menu_exit_option ]] && is_menu_back_option=1
    [[ $is_menu_back_option || $is_menu_exit_option ]] && is_prompt_min=0

    [[ ${is_opt_msg:-} ]] && msg "$is_opt_msg"
    [[ ! ${is_opt_input_msg:-} ]] && is_opt_input_msg="请选择 [\e[91m${is_prompt_min}-${#is_tmp_list[@]}\e[0m]:"
    [[ ${is_tmp_list:-} ]] && show_list "${is_tmp_list[@]}"
    [[ $is_menu_exit_option ]] && ui_menu_item 0 "退出"
    [[ $is_menu_back_option ]] && ui_menu_item 0 "返回主菜单"
    while :; do
        ui_print_inline "$is_opt_input_msg"
        read REPLY || {
            [[ $is_menu_exit_option || $is_emtpy_exit ]] && is_menu_exit=1
            ask_cleanup
            return 1
        }
        [[ ! $REPLY && $is_emtpy_exit ]] && exit
        if [[ $REPLY == 0 ]]; then
            if [[ $is_menu_exit_option ]]; then
                is_menu_exit=1
                ask_cleanup
                return 1
            fi
            if [[ $is_menu_back_option ]]; then
                is_menu_back=1
                msg "返回主菜单"
                ask_cleanup
                return 1
            fi
        fi
        [[ ! $REPLY && $is_default_arg ]] && export $is_ask_set=$is_default_arg && break
        [[ "$REPLY" == "${is_str:-}2${is_get:-}3${is_opt:-}3" && $is_ask_set == 'is_main_pick' ]] && {
            msg "\n${is_get}2${is_str}3${is_msg}3b${is_tmp}o${is_opt}y\n" && exit
        }
        if [[ ! ${is_tmp_list:-} ]]; then
            [[ $(grep port <<<$is_ask_set) ]] && {
                [[ ! $(is_test port "$REPLY") ]] && {
                    msg "$is_err 请输入正确的端口, 可选(1-65535)"
                    continue
                }
                if [[ $(is_test port_used $REPLY) && $is_ask_set != 'door_port' ]]; then
                    msg "$is_err 无法使用 ($REPLY) 端口."
                    continue
                fi
            }
            [[ $(grep path <<<$is_ask_set) && ! $(is_test path "$REPLY") ]] && {
                [[ ! $tmp_uuid ]] && get_uuid
                msg "$is_err 请输入正确的路径, 例如: /$tmp_uuid"
                continue
            }
            [[ $(grep uuid <<<$is_ask_set) && ! $(is_test uuid "$REPLY") ]] && {
                [[ ! $tmp_uuid ]] && get_uuid
                msg "$is_err 请输入正确的 UUID, 例如: $tmp_uuid"
                continue
            }
            [[ $is_ask_set == 'is_anytls_domain' && ! $(is_test domain "$REPLY") ]] && {
                msg "$is_err 请输入正确的域名, 例如: example.com"
                continue
            }
            [[ $(grep ^y$ <<<$is_ask_set) ]] && {
                [[ $(grep -i ^y$ <<<"$REPLY") ]] && break
                msg "请输入 (y)"
                continue
            }
            [[ $REPLY ]] && export $is_ask_set=$REPLY && msg "使用: ${!is_ask_set}" && break
        else
            is_ask_result=
            [[ $(is_test number "$REPLY") ]] && is_ask_result=${is_tmp_list[$REPLY - 1]}
            [[ ${is_ask_result:-} ]] && export $is_ask_set="$is_ask_result" && msg "选择: ${!is_ask_set}" && break
        fi

        msg "输入${is_err}"
    done
    ask_cleanup
}

render_server_config_json() {
    local config_log config_dns config_ntp config_outbounds

    config_log='log:{output:"/var/log/'$is_core'/access.log",level:"info","timestamp":true}'
    config_dns='dns:{}'
    config_ntp='ntp:{"enabled":true,"server":"time.apple.com"},'
    if [[ -f $is_config_json ]]; then
        [[ $(jq .ntp.enabled "$is_config_json") != "true" ]] && config_ntp=
    else
        [[ ! $is_ntp_on ]] && config_ntp=
    fi
    config_outbounds='outbounds:[{tag:"direct",type:"direct"}]'
    jq "{$config_log,$config_dns,$config_ntp$config_outbounds}" <<<'{}'
}

# create file
create() {
    case $1 in
    server)
        is_tls=none
        get new
        # listen
        is_listen='listen: "::"'
        # file name
        if [[ $host ]]; then
            is_config_name=$2-${host}.json
            is_listen='listen: "127.0.0.1"'
        elif [[ $is_anytls_domain ]]; then
            is_config_name=$2-${is_anytls_domain}.json
        else
            is_config_name=$2-${port}.json
        fi
        is_json_file=$is_conf_dir/$is_config_name
        # get json
        is_add_public_key=
        is_root_extra_json=
        [[ $is_change || ! $json_str ]] && get protocol $2
        [[ $net == "reality" ]] && is_add_public_key=",outbounds:[{type:\"direct\"},{tag:\"public_key_$is_public_key\",type:\"direct\"}]"
        is_new_json=$(jq "{inbounds:[{tag:\"$is_config_name\",type:\"$is_protocol\",$is_listen,listen_port:$port,$json_str}]$is_add_public_key$is_root_extra_json}" <<<{})
        [[ $is_test_json ]] && return # tmp test
        # only show json, dont save to file.
        [[ $is_gen ]] && {
            msg
            jq <<<$is_new_json
            msg
            return
        }
        # del old file
        [[ $is_config_file ]] && is_no_del_msg=1 && del $is_config_file
        if [[ $is_anytls_acme_mode ]]; then
            commit_server_config_with_validation
            _green "AnyTLS ACME 配置已写入并通过启动验证。"
        else
            # save json to file
            safe_write_file "$is_json_file" "$is_new_json"
            if [[ $is_new_install ]]; then
                # config.json
                create config.json
            fi
            # caddy auto tls
            [[ $is_caddy && $host && ! $is_no_auto_tls ]] && {
                create caddy $net
            }
            # restart core
            manage restart &
        fi
        ;;
    client)
        is_tls=tls
        is_client=1
        get info $2
        [[ ! $is_client_id_json ]] && err "($is_config_name) 不支持生成客户端配置."
        is_new_json=$(jq '{outbounds:[{tag:'\"$is_config_name\"',protocol:'\"$is_protocol\"','"$is_client_id_json"','"$is_stream"'}]}' <<<{})
        msg
        jq <<<$is_new_json
        msg
        ;;
    caddy)
        load caddy.sh
        [[ $is_install_caddy ]] && caddy_config new
        [[ ! $(grep "$is_caddy_conf" $is_caddyfile) ]] && {
            safe_append_file "$is_caddyfile" "import $is_caddy_conf/*.conf"
        }
        [[ ! -d $is_caddy_conf ]] && mkdir -p $is_caddy_conf
        caddy_config $2
        manage restart caddy &
        ;;
    config.json)
        is_server_config_json=$(render_server_config_json)
        safe_write_file "$is_config_json" "$is_server_config_json"
        [[ ! $is_skip_config_restart ]] && manage restart &
        ;;
    esac
}

# change config file
change() {
    is_change=1
    is_dont_show_info=1
    if [[ $2 ]]; then
        case ${2,,} in
        full)
            is_change_id=full
            ;;
        new)
            is_change_id=0
            ;;
        port)
            is_change_id=1
            ;;
        host)
            is_change_id=2
            ;;
        path)
            is_change_id=3
            ;;
        pass | passwd | password)
            is_change_id=4
            ;;
        id | uuid)
            is_change_id=5
            ;;
        ssm | method | ss-method | ss_method)
            is_change_id=6
            ;;
        dda | door-addr | door_addr)
            is_change_id=7
            ;;
        ddp | door-port | door_port)
            is_change_id=8
            ;;
        key | publickey | privatekey)
            is_change_id=9
            ;;
        sni | servername | servernames)
            is_change_id=10
            ;;
        web | proxy-site)
            is_change_id=11
            ;;
        *)
            [[ $is_try_change ]] && return
            err "无法识别 ($2) 更改类型."
            ;;
        esac
    fi
    [[ $is_try_change ]] && return
    [[ $is_dont_auto_exit ]] && {
        get info $1 || return 1
    } || {
        [[ $is_change_id ]] && {
            is_change_msg=${change_list[$is_change_id]}
            [[ $is_change_id == 'full' ]] && {
                [[ $3 ]] && is_change_msg="更改多个参数" || is_change_msg=
            }
            [[ $is_change_msg ]] && _green "\n快速执行: $is_change_msg"
        }
        info $1 || return 1
        [[ $is_auto_get_config ]] && msg "\n自动选择: $is_config_file"
    }
    is_old_net=$net
    [[ $is_tcp_http ]] && net=http
    [[ $host ]] && net=$is_protocol-$net-tls
    [[ $is_reality && $net_type =~ 'http' ]] && net=rh2

    [[ $3 == 'auto' ]] && is_auto=1
    # if is_dont_show_info exist, cant show info.
    is_dont_show_info=
    # if not prefer args, show change list and then get change id.
    [[ ! $is_change_id ]] && {
        ask set_change_list || return 1
        is_change_id=${is_can_change[$REPLY - 1]}
    }
    case $is_change_id in
    full)
        add $net ${@:3}
        ;;
    0)
        # new protocol
        is_set_new_protocol=1
        add ${@:3}
        ;;
    1)
        # new port
        is_new_port=$3
        [[ $host && ! $is_caddy || $is_no_auto_tls ]] && err "($is_config_file) 不支持更改端口, 因为没啥意义."
        if [[ $is_new_port && ! $is_auto ]]; then
            [[ ! $(is_test port $is_new_port) ]] && err "请输入正确的端口, 可选(1-65535)"
            [[ $is_new_port != 443 && $(is_test port_used $is_new_port) ]] && err "无法使用 ($is_new_port) 端口"
        fi
        [[ $is_auto ]] && get_port && is_new_port=$tmp_port
        [[ ! $is_new_port ]] && ask string is_new_port "请输入新端口:"
        if [[ $is_caddy && $host ]]; then
            net=$is_old_net
            is_https_port=$is_new_port
            load caddy.sh
            caddy_config $net
            manage restart caddy &
            info
        else
            add $net $is_new_port
        fi
        ;;
    2)
        # new host
        is_new_host=$3
        [[ ! $host ]] && err "($is_config_file) 不支持更改域名."
        [[ ! $is_new_host ]] && ask string is_new_host "请输入新域名:"
        old_host=$host # del old host
        add $net $is_new_host
        ;;
    3)
        # new path
        is_new_path=$3
        [[ ! $path ]] && err "($is_config_file) 不支持更改路径."
        [[ $is_auto ]] && get_uuid && is_new_path=/$tmp_uuid
        [[ ! $is_new_path ]] && ask string is_new_path "请输入新路径:"
        add $net auto auto $is_new_path
        ;;
    4)
        # new password
        is_new_pass=$3
        if [[ $ss_password || $password ]]; then
            [[ $is_auto ]] && {
                get_uuid && is_new_pass=$tmp_uuid
                [[ $ss_password ]] && is_new_pass=$(get ss2022)
            }
        else
            err "($is_config_file) 不支持更改密码."
        fi
        [[ ! $is_new_pass ]] && ask string is_new_pass "请输入新密码:"
        password=$is_new_pass
        ss_password=$is_new_pass
        is_socks_pass=$is_new_pass
        add $net
        ;;
    5)
        # new uuid
        is_new_uuid=$3
        [[ ! $uuid ]] && err "($is_config_file) 不支持更改 UUID."
        [[ $is_auto ]] && get_uuid && is_new_uuid=$tmp_uuid
        [[ ! $is_new_uuid ]] && ask string is_new_uuid "请输入新 UUID:"
        add $net auto $is_new_uuid
        ;;
    6)
        # new method
        is_new_method=$3
        [[ $net != 'ss' ]] && err "($is_config_file) 不支持更改加密方式."
        [[ $is_auto ]] && is_new_method=$is_random_ss_method
        [[ ! $is_new_method ]] && {
            ask set_ss_method || return 1
            is_new_method=$ss_method
        }
        add $net auto auto $is_new_method
        ;;
    7)
        # new remote addr
        is_new_door_addr=$3
        [[ $net != 'direct' ]] && err "($is_config_file) 不支持更改目标地址."
        [[ ! $is_new_door_addr ]] && ask string is_new_door_addr "请输入新的目标地址:"
        door_addr=$is_new_door_addr
        add $net
        ;;
    8)
        # new remote port
        is_new_door_port=$3
        [[ $net != 'direct' ]] && err "($is_config_file) 不支持更改目标端口."
        [[ ! $is_new_door_port ]] && {
            ask string door_port "请输入新的目标端口:"
            is_new_door_port=$door_port
        }
        add $net auto auto $is_new_door_port
        ;;
    9)
        # new is_private_key is_public_key
        is_new_private_key=$3
        is_new_public_key=$4
        [[ ! $is_reality ]] && err "($is_config_file) 不支持更改密钥."
        if [[ $is_auto ]]; then
            get_pbk
            add $net
        else
            [[ $is_new_private_key && ! $is_new_public_key ]] && {
                err "无法找到 Public key."
            }
            [[ ! $is_new_private_key ]] && ask string is_new_private_key "请输入新 Private key:"
            [[ ! $is_new_public_key ]] && ask string is_new_public_key "请输入新 Public key:"
            if [[ $is_new_private_key == $is_new_public_key ]]; then
                err "Private key 和 Public key 不能一样."
            fi
            is_tmp_json=$(mktemp "${TMPDIR:-/tmp}/sing-box-key-test.XXXXXX")
            cp -f $is_conf_dir/$is_config_file $is_tmp_json
            sed -i s#$is_private_key #$is_new_private_key# $is_tmp_json
            $is_core_bin check -c $is_tmp_json &>/dev/null
            if [[ $? != 0 ]]; then
                is_key_err=1
                is_key_err_msg="Private key 无法通过测试."
            fi
            sed -i s#$is_new_private_key #$is_new_public_key# $is_tmp_json
            $is_core_bin check -c $is_tmp_json &>/dev/null
            if [[ $? != 0 ]]; then
                is_key_err=1
                is_key_err_msg+="Public key 无法通过测试."
            fi
            rm -f $is_tmp_json
            [[ $is_key_err ]] && err $is_key_err_msg
            is_private_key=$is_new_private_key
            is_public_key=$is_new_public_key
            is_test_json=
            add $net
        fi
        ;;
    10)
        # new serverName
        is_new_servername=$3
        [[ ! $is_reality ]] && err "($is_config_file) 不支持更改 serverName."
        [[ $is_auto ]] && is_new_servername=$is_random_servername
        [[ ! $is_new_servername ]] && ask string is_new_servername "请输入新的 serverName:"
        is_servername=$is_new_servername
        add $net
        ;;
    11)
        # new proxy site
        is_new_proxy_site=$3
        [[ ! $is_caddy && ! $host ]] && {
            err "($is_config_file) 不支持更改伪装网站."
        }
        [[ ! -f $is_caddy_conf/${host}.conf.add ]] && err "无法配置伪装网站."
        [[ ! $is_new_proxy_site ]] && ask string is_new_proxy_site "请输入新的伪装网站 (例如 example.com):"
        proxy_site=$(sed 's#^.*//##;s#/$##' <<<$is_new_proxy_site)
        load caddy.sh
        caddy_config proxy
        manage restart caddy &
        msg "\n已更新伪装网站为: $(_green $proxy_site) \n"
        ;;
    12)
        # new socks user
        [[ ! $is_socks_user ]] && err "($is_config_file) 不支持更改用户名 (Username)."
        ask string is_socks_user "请输入新用户名 (Username):"
        add $net
        ;;
    esac
}

# delete config.
del() {
    # dont get ip
    is_dont_get_ip=1
    [[ $is_conf_dir_empty ]] && return # not found any json file.
    # get a config file
    if [[ ! $is_config_file ]]; then
        get info $1 || return 1
    fi
    if [[ $is_config_file ]]; then
        if [[ $is_main_start && ! $is_no_del_msg ]]; then
            msg "\n是否删除配置文件?: $is_config_file"
            pause
        fi
        safe_remove_path "$is_conf_dir/$is_config_file"
        [[ ! $is_new_json ]] && manage restart &
        [[ ! $is_no_del_msg ]] && _green "\n已删除: $is_config_file\n"

        [[ $is_caddy ]] && {
            is_del_host=$host
            [[ $is_change ]] && {
                [[ ! $old_host ]] && return # no host exist or not set new host;
                is_del_host=$old_host
            }
            [[ $is_del_host && $host != $old_host && -f $is_caddy_conf/$is_del_host.conf ]] && {
                safe_remove_path "$is_caddy_conf/$is_del_host.conf" "$is_caddy_conf/$is_del_host.conf.add"
                [[ ! $is_new_json ]] && manage restart caddy &
            }
        }
    fi
    if [[ ! $(ls $is_conf_dir | grep .json) && ! $is_change ]]; then
        warn "当前配置目录为空! 因为你刚刚删除了最后一个配置文件."
        is_conf_dir_empty=1
    fi
    unset is_dont_get_ip
    [[ $is_dont_auto_exit ]] && unset is_config_file
}

# uninstall
uninstall() {
    local path
    if [[ $is_caddy ]]; then
        is_tmp_list=("卸载 $is_core_name" "卸载 ${is_core_name} & Caddy")
        ask list is_do_uninstall || return 1
    else
        ask string y "是否卸载 ${is_core_name}? [y]:"
    fi
    manage stop &>/dev/null
    manage disable &>/dev/null
    backup_standard_managed_paths
    safe_remove_path "$is_config_json" "$is_core_bin" "$is_sh_bin" "${is_sh_bin/$is_core/sb}" "$is_log_dir"
    for path in "$is_conf_dir"/*.json; do
        [[ -e $path || -L $path ]] && safe_remove_path "$path"
    done
    for path in "$is_sh_dir"/*; do
        [[ -e $path || -L $path ]] && safe_remove_path "$path"
    done
    rmdir "$is_conf_dir" "$is_core_dir/bin" "$is_sh_dir" "$is_core_dir" "$is_log_dir" 2>/dev/null || true
    if [[ $is_systemd ]]; then
        safe_remove_path "/lib/systemd/system/$is_core.service" "/etc/systemd/system/$is_core.service"
    elif [[ $is_openrc ]]; then
        safe_remove_path "/etc/init.d/$is_core"
    fi
    safe_remove_shell_aliases "${is_shell_profile:-/root/.bashrc}"
    # uninstall caddy; 2 is ask result
    if [[ $REPLY == '2' ]]; then
        manage stop caddy &>/dev/null
        manage disable caddy &>/dev/null
        backup_glob_before_write "$is_caddy_conf/*.conf"
        backup_glob_before_write "$is_caddy_conf/*.conf.add"
        for path in "$is_caddy_conf"/*.conf "$is_caddy_conf"/*.conf.add; do
            [[ -e $path || -L $path ]] && safe_remove_path "$path"
        done
        if [[ $is_systemd ]]; then
            safe_remove_path "$is_caddyfile" "$is_caddy_bin" "/lib/systemd/system/caddy.service" "/etc/systemd/system/caddy.service"
        elif [[ $is_openrc ]]; then
            safe_remove_path "$is_caddyfile" "$is_caddy_bin" "/etc/init.d/caddy"
        fi
        rmdir "$is_caddy_conf" "$is_caddy_dir/sites" "$is_caddy_dir" 2>/dev/null || true
    fi
    [[ $is_install_sh ]] && return # reinstall
    _green "\n卸载完成!"
    msg "脚本哪里需要完善? 请反馈"
    msg "反馈问题) $(msg_ul https://github.com/${is_sh_repo}/issues)\n"
}

# manage run status
manage() {
    [[ $is_dont_auto_exit ]] && return
    case $1 in
    1 | start)
        is_do=start
        is_do_msg=启动
        is_test_run=1
        ;;
    2 | stop)
        is_do=stop
        is_do_msg=停止
        ;;
    3 | r | restart)
        is_do=restart
        is_do_msg=重启
        is_test_run=1
        ;;
    *)
        is_do=$1
        is_do_msg=$1
        ;;
    esac
    case $2 in
    caddy)
        is_do_name=$2
        is_run_bin=$is_caddy_bin
        is_do_name_msg=Caddy
        ;;
    *)
        is_do_name=$is_core
        is_run_bin=$is_core_bin
        is_do_name_msg=$is_core_name
        ;;
    esac
    if [[ $is_systemd ]]; then
        systemctl $is_do $is_do_name 2>/dev/null
    elif [[ $is_openrc ]]; then
        case $is_do in
        enable)
            rc-update add $is_do_name default 2>/dev/null
            ;;
        disable)
            rc-update del $is_do_name default 2>/dev/null
            ;;
        *)
            rc-service $is_do_name $is_do 2>/dev/null
            ;;
        esac
    fi
    [[ $is_test_run && ! $is_new_install ]] && {
        sleep 2
        if [[ ! $(pgrep -f $is_run_bin 2>/dev/null || grep -l "$is_run_bin" /proc/*/cmdline 2>/dev/null) ]]; then
            is_run_fail=${is_do_name_msg,,}
            [[ ! $is_no_manage_msg ]] && {
                msg
                warn "($is_do_msg) $is_do_name_msg 失败"
                _yellow "检测到运行失败, 自动执行测试运行."
                get test-run
                _yellow "测试结束, 请按 Enter 退出."
            }
        fi
    }
}

assert_anytls_core_version() {
    # 中文注释：AnyTLS 从 sing-box 1.12.0 起可用。
    is_core_version_ge "$is_core_ver" "1.12.0" || {
        err "当前 sing-box 版本 ($is_core_ver) 不支持 AnyTLS，请先升级 sing-box core 到 1.12.0 或更高版本。"
    }
}

assert_core_acme_capability() {
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

assert_anytls_acme_port_available() {
    if [[ $(is_test port_used 443) ]]; then
        err "TCP 443 已被占用，AnyTLS ACME 域名模式无法继续。请先停止占用 443 的服务。"
    fi
}

assert_anytls_acme_domain_dns() {
    local domain=$1
    local server_ipv4 server_ipv6 domain_a_json domain_aaaa_json
    local domain_a_records domain_aaaa_records
    local needs_confirm=

    # 中文注释：优先单独探测公网 IPv4 / IPv6；如果失败，再回退到当前脚本已探测的 ip。
    server_ipv4=$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}')
    server_ipv6=$(_wget -6 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}')
    [[ ! $server_ipv4 && ${ip:-} && $ip != *:* ]] && server_ipv4=$ip
    [[ ! $server_ipv6 && ${ip:-} == *:* ]] && server_ipv6=$ip

    domain_a_json=$(_wget -qO- --header="accept: application/dns-json" "https://one.one.one.one/dns-query?name=$domain&type=A" 2>/dev/null || true)
    domain_aaaa_json=$(_wget -qO- --header="accept: application/dns-json" "https://one.one.one.one/dns-query?name=$domain&type=AAAA" 2>/dev/null || true)
    domain_a_records=$(jq -r '.Answer[]? | select(.type == 1) | .data' <<<"$domain_a_json" 2>/dev/null || true)
    domain_aaaa_records=$(jq -r '.Answer[]? | select(.type == 28) | .data' <<<"$domain_aaaa_json" 2>/dev/null || true)

    [[ ! $domain_a_records && ! $domain_aaaa_records ]] && {
        err "域名 ($domain) 未查询到 A 或 AAAA 记录，AnyTLS ACME 无法继续。"
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

preflight_anytls_acme() {
    # 中文注释：仅 AnyTLS 域名 / ACME 模式调用；任何硬失败都必须发生在生产配置写入前。
    assert_anytls_core_version
    assert_core_acme_capability
    assert_anytls_acme_domain_dns "$is_anytls_acme_domain"
    assert_anytls_acme_port_available

    load firewall.sh
    ensure_anytls_acme_firewall_443
    warn_anytls_acme_external_firewall
}

render_pending_server_config_json() {
    # 中文注释：候选 check 优先复用现有生产 config.json；首次安装时只渲染临时基础配置，不提前落盘。
    if [[ -f $is_config_json ]]; then
        cat "$is_config_json"
        return
    fi

    render_server_config_json
}

write_server_config_json_if_missing() {
    local server_config_json

    [[ -f $is_config_json ]] && return 0
    server_config_json=$(render_server_config_json) || return 1
    safe_write_file "$is_config_json" "$server_config_json"
}

path_is_in_systemd_read_write_paths() {
    local target=$1
    local paths=$2
    local path

    [[ $target ]] || return 1

    for path in $paths; do
        [[ $path == "$target" ]] && return 0
    done

    return 1
}

get_systemd_service_property() {
    local property=$1

    systemctl show "${is_core:-sing-box}" -p "$property" --value 2>/dev/null || true
}

systemd_protect_system_needs_read_write_paths() {
    local protect_system=$1

    case "$protect_system" in
    full | strict | yes | true)
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

render_anytls_acme_systemd_override() {
    local acme_dir=$1
    local log_dir=${is_log_dir:-/var/log/${is_core:-sing-box}}

    printf '[Service]\n'
    printf 'ReadWritePaths=%s %s\n' "$acme_dir" "$log_dir"
}

ensure_anytls_acme_systemd_writable_paths() {
    local protect_system
    local read_write_paths
    local override_dir
    local override_file
    local override_content

    # 中文注释：仅 AnyTLS ACME + systemd 环境需要处理 ProtectSystem 导致的 ACME 目录只读问题。
    [[ $is_anytls_acme_mode ]] || return 0
    [[ $is_systemd ]] || return 0
    [[ $is_anytls_acme_data_dir ]] || return 0

    protect_system=$(get_systemd_service_property ProtectSystem)
    systemd_protect_system_needs_read_write_paths "$protect_system" || return 0

    read_write_paths=$(get_systemd_service_property ReadWritePaths)
    path_is_in_systemd_read_write_paths "$is_anytls_acme_data_dir" "$read_write_paths" && return 0

    override_dir="/etc/systemd/system/${is_core:-sing-box}.service.d"
    override_file="$override_dir/10-anytls-acme.conf"
    override_content=$(render_anytls_acme_systemd_override "$is_anytls_acme_data_dir") || return 1

    safe_ensure_dir "$override_dir" || return 1
    safe_write_file "$override_file" "$override_content" || return 1

    systemctl daemon-reload >/dev/null 2>&1 || {
        err "systemd daemon-reload 失败，无法应用 AnyTLS ACME 可写路径 override。"
        return 1
    }

    msg "$is_warn 已为 AnyTLS ACME 添加 systemd ReadWritePaths override: $override_file"
}

check_pending_server_config() {
    local tmp_conf_dir tmp_file tmp_config_json check_log

    tmp_conf_dir=$(mktemp -d "${TMPDIR:-/tmp}/sing-box-conf-check.XXXXXX") || {
        err "创建临时配置目录失败。"
        return 1
    }
    tmp_config_json=$(mktemp "${TMPDIR:-/tmp}/sing-box-config-check.XXXXXX") || {
        rm -rf "$tmp_conf_dir"
        err "创建临时基础配置失败。"
        return 1
    }
    check_log=$(mktemp "${TMPDIR:-/tmp}/sing-box-check.XXXXXX") || {
        rm -rf "$tmp_conf_dir"
        rm -f "$tmp_config_json"
        err "创建临时检查日志失败。"
        return 1
    }

    cp -a "$is_conf_dir"/. "$tmp_conf_dir"/ 2>/dev/null || true

    render_pending_server_config_json >"$tmp_config_json" || {
        rm -rf "$tmp_conf_dir"
        rm -f "$tmp_config_json" "$check_log"
        err "渲染临时基础配置失败。"
        return 1
    }

    tmp_file="$tmp_conf_dir/$is_config_name"
    printf '%s\n' "$is_new_json" >"$tmp_file" || {
        rm -rf "$tmp_conf_dir"
        rm -f "$tmp_config_json" "$check_log"
        err "写入临时配置失败。"
        return 1
    }

    if ! $is_core_bin check -c "$tmp_config_json" -C "$tmp_conf_dir" >"$check_log" 2>&1; then
        cat "$check_log"
        rm -rf "$tmp_conf_dir"
        rm -f "$tmp_config_json" "$check_log"
        return 1
    fi

    rm -rf "$tmp_conf_dir"
    rm -f "$tmp_config_json" "$check_log"
}

is_core_process_running() {
    if pgrep -f "$is_core_bin" >/dev/null 2>&1; then
        return 0
    fi
    grep -l "$is_core_bin" /proc/*/cmdline >/dev/null 2>&1
}

restart_core_and_verify() {
    local run_log old_no_manage_msg=

    old_no_manage_msg=${is_no_manage_msg-}
    is_no_manage_msg=1
    manage restart || true
    if [[ $old_no_manage_msg ]]; then
        is_no_manage_msg=$old_no_manage_msg
    else
        unset is_no_manage_msg
    fi

    if is_core_process_running; then
        return 0
    fi

    warn "sing-box 重启失败，准备输出前台测试日志。"

    run_log=$(mktemp "${TMPDIR:-/tmp}/sing-box-run.XXXXXX") || return 1
    $is_core_bin run -c "$is_config_json" -C "$is_conf_dir" >"$run_log" 2>&1
    cat "$run_log"
    rm -f "$run_log"

    return 1
}

print_anytls_acme_failure_guidance() {
    msg
    msg "AnyTLS ACME 添加失败。"
    msg
    msg "已执行检查："
    msg "- sing-box version"
    msg "- ACME capability"
    msg "- DNS A / AAAA"
    msg "- TCP 443 local availability"
    msg "- local firewall backend"
    msg "- sing-box config check"
    msg "- sing-box restart"
    msg
    msg "请继续人工检查："
    msg "1. 云厂商安全组是否放行 TCP 443"
    msg "2. Cloudflare 是否为 DNS only"
    msg "3. 域名是否存在错误 AAAA 记录"
    msg "4. Let's Encrypt 是否触发 rate limit"
    msg "5. sing-box core 是否包含 with_acme"
    msg "6. journalctl -u sing-box -n 200 --no-pager"
    msg
}

rollback_or_remove_failed_anytls_config() {
    # 中文注释：优先使用现有 rollback 机制；如果不可用，至少删除刚写入的新配置。
    if type rollback_latest_backup >/dev/null 2>&1; then
        rollback_latest_backup --yes || {
            warn "自动 rollback 失败，尝试删除新 AnyTLS 配置。"
            safe_remove_path "$is_json_file" || warn "删除新 AnyTLS 配置失败: $is_json_file"
            manage restart || true
        }
        return
    fi

    warn "未找到 rollback_latest_backup，尝试删除新 AnyTLS 配置。"
    safe_remove_path "$is_json_file" || warn "删除新 AnyTLS 配置失败: $is_json_file"
    manage restart || true
}

fail_anytls_acme_commit_after_write() {
    local message=$1
    local show_guidance=${2:-}

    [[ $IS_BACKUP_ACTIVE == true ]] && finalize_backup_transaction
    rollback_or_remove_failed_anytls_config
    [[ $show_guidance == true ]] && print_anytls_acme_failure_guidance
    err "$message"
    return 1
}

commit_server_config_with_validation() {
    local should_finalize=false

    # 中文注释：AnyTLS ACME 必须先在临时路径完成 sing-box check，再开启生产写入事务。
    if ! check_pending_server_config; then
        print_anytls_acme_failure_guidance
        err "sing-box 配置检查失败，未写入生产配置。"
        return 1
    fi

    begin_backup_transaction_if_needed "add-anytls-acme" && should_finalize=true

    write_server_config_json_if_missing || {
        fail_anytls_acme_commit_after_write "写入基础 config.json 失败，已尝试回滚。"
        return 1
    }

    if [[ $is_anytls_acme_data_dir ]]; then
        safe_ensure_dir "$is_anytls_acme_data_dir" || {
            fail_anytls_acme_commit_after_write "创建 ACME 数据目录失败，已尝试回滚。"
            return 1
        }

        ensure_anytls_acme_systemd_writable_paths || {
            fail_anytls_acme_commit_after_write "配置 AnyTLS ACME systemd 可写路径失败，已尝试回滚。"
            return 1
        }
    fi

    safe_write_file "$is_json_file" "$is_new_json" || {
        fail_anytls_acme_commit_after_write "写入 AnyTLS ACME 配置失败，已尝试回滚。"
        return 1
    }

    if ! restart_core_and_verify; then
        warn "AnyTLS ACME 配置导致 sing-box 启动失败，开始回滚。"
        fail_anytls_acme_commit_after_write "AnyTLS ACME 添加失败，已尝试回滚。请根据上方日志检查 DNS、TCP 443、防火墙、ACME 限流或 with_acme。" true
        return 1
    fi

    if [[ $should_finalize == true || $IS_BACKUP_ACTIVE == true ]]; then
        finalize_backup_transaction
    fi
}

run_with_backup_transaction() {
    local operation=$1
    local should_finalize=false
    local status
    shift

    begin_backup_transaction_if_needed "$operation" && should_finalize=true
    "$@"
    status=$?
    [[ $should_finalize == true ]] && finalize_backup_transaction
    return $status
}

# add a config
add() {
    is_lower=${1,,}
    if [[ $is_lower ]]; then
        case $is_lower in
        ws | tcp | quic | http)
            is_new_protocol=VMess-${is_lower^^}
            ;;
        wss | h2 | hu | vws | vh2 | vhu | tws | th2 | thu)
            is_new_protocol=$(sed -E "s/^V/VLESS-/;s/^T/Trojan-/;/^(W|H)/{s/^/VMess-/};s/WSS/WS/;s/HU/HTTPUpgrade/" <<<${is_lower^^})-TLS
            ;;
        r | reality)
            is_new_protocol=VLESS-REALITY
            ;;
        rh2)
            is_new_protocol=VLESS-HTTP2-REALITY
            ;;
        ss)
            is_new_protocol=Shadowsocks
            ;;
        door | direct)
            is_new_protocol=Direct
            ;;
        tuic)
            is_new_protocol=TUIC
            ;;
        hy | hy2 | hysteria*)
            is_new_protocol=Hysteria2
            ;;
        trojan)
            is_new_protocol=Trojan
            ;;
        anytls)
            is_new_protocol=AnyTLS
            ;;
        socks)
            is_new_protocol=Socks
            ;;
        *)
            for v in ${protocol_list[@]}; do
                [[ $(grep -E -i "^$is_lower$" <<<$v) ]] && is_new_protocol=$v && break
            done

            [[ ! $is_new_protocol ]] && err "无法识别 ($1), 请使用: $is_core add [protocol] [args... | auto]"
            ;;
        esac
    fi

    # no prefer protocol
    if [[ ! $is_new_protocol ]]; then
        ask set_protocol || return 1
    fi

    [[ ${is_new_protocol,,} == 'anytls' ]] && assert_anytls_core_version

    case ${is_new_protocol,,} in
    *-tls)
        is_use_tls=1
        is_use_host=$2
        is_use_uuid=$3
        is_use_path=$4
        is_add_opts="[host] [uuid] [/path]"
        ;;
    vmess* | tuic*)
        is_use_port=$2
        is_use_uuid=$3
        is_add_opts="[port] [uuid]"
        ;;
    trojan* | hysteria*)
        is_use_port=$2
        is_use_pass=$3
        is_add_opts="[port] [password]"
        ;;
    *reality*)
        is_reality=1
        is_use_port=$2
        is_use_uuid=$3
        is_use_servername=$4
        is_add_opts="[port] [uuid] [sni]"
        ;;
    shadowsocks)
        is_use_port=$2
        is_use_pass=$3
        is_use_method=$4
        is_add_opts="[port] [password] [method]"
        ;;
    direct)
        is_use_port=$2
        is_use_door_addr=$3
        is_use_door_port=$4
        is_add_opts="[port] [remote_addr] [remote_port]"
        ;;
    anytls*)
        is_use_port=$2
        is_use_pass=$3
        [[ $4 ]] && is_anytls_domain=$4
        is_add_opts="[port] [password] [domain]"
        ;;
    socks)
        is_socks=1
        is_use_port=$2
        is_use_socks_user=$3
        is_use_socks_pass=$4
        is_add_opts="[port] [username] [password]"
        ;;
    esac

    if [[ $is_main_start && ${is_new_protocol,,} == 'anytls' && ! $2 && ! $is_change && ! $is_gen ]]; then
        ask set_anytls_cert || return 1
        if [[ $is_anytls_cert == yes ]]; then
            ask string is_anytls_domain "请输入 AnyTLS 证书域名:"
            is_use_port=443
            is_main_anytls_acme=1
        fi
    fi

    [[ $1 && ! $is_change ]] && {
        msg "\n使用协议: $is_new_protocol"
        # err msg tips
        is_err_tips="\n\n请使用: $(_green $is_core add $1 $is_add_opts) 来添加 $is_new_protocol 配置"
    }

    # remove old protocol args
    if [[ $is_set_new_protocol ]]; then
        case $is_old_net in
        h2 | ws | httpupgrade)
            old_host=$host
            [[ ! $is_use_tls ]] && unset host is_no_auto_tls
            ;;
        reality)
            net_type=
            [[ ! $(grep -i reality <<<$is_new_protocol) ]] && is_reality=
            ;;
        ss)
            [[ $(is_test uuid $ss_password) ]] && uuid=$ss_password
            ;;
        esac
        [[ ! $(is_test uuid $uuid) ]] && uuid=
        [[ $(is_test uuid $password) ]] && uuid=$password
    fi

    # no-auto-tls only use h2,ws,grpc
    if [[ $is_no_auto_tls && ! $is_use_tls ]]; then
        err "$is_new_protocol 不支持手动配置 tls."
    fi

    # prefer args.
    if [[ $2 || $is_main_anytls_acme ]]; then
        for v in is_use_port is_use_uuid is_use_host is_use_path is_use_pass is_use_method is_use_door_addr is_use_door_port; do
            [[ ${!v} == 'auto' ]] && unset $v
        done

        if [[ $is_use_port ]]; then
            [[ ! $(is_test port ${is_use_port}) ]] && {
                err "($is_use_port) 不是一个有效的端口. $is_err_tips"
            }
            if [[ $(is_test port_used $is_use_port) && ! $is_gen ]]; then
                if [[ ${is_new_protocol,,} == 'anytls' && $is_anytls_domain && ! $is_change ]]; then
                    :
                else
                    err "无法使用 ($is_use_port) 端口. $is_err_tips"
                fi
            fi
            port=$is_use_port
        fi
        if [[ $is_use_door_port ]]; then
            [[ ! $(is_test port ${is_use_door_port}) ]] && {
                err "(${is_use_door_port}) 不是一个有效的目标端口. $is_err_tips"
            }
            door_port=$is_use_door_port
        fi
        if [[ $is_use_uuid ]]; then
            [[ ! $(is_test uuid $is_use_uuid) ]] && {
                err "($is_use_uuid) 不是一个有效的 UUID. $is_err_tips"
            }
            uuid=$is_use_uuid
        fi
        if [[ $is_use_path ]]; then
            [[ ! $(is_test path $is_use_path) ]] && {
                err "($is_use_path) 不是有效的路径. $is_err_tips"
            }
            path=$is_use_path
        fi
        if [[ $is_use_method ]]; then
            is_tmp_use_name=加密方式
            is_tmp_list=${ss_method_list[@]}
            for v in ${is_tmp_list[@]}; do
                [[ $(grep -E -i "^${is_use_method}$" <<<$v) ]] && is_tmp_use_type=$v && break
            done
            [[ ! ${is_tmp_use_type} ]] && {
                warn "(${is_use_method}) 不是一个可用的${is_tmp_use_name}."
                msg "${is_tmp_use_name}可用如下: "
                for v in ${is_tmp_list[@]}; do
                    msg "\t\t$v"
                done
                msg "$is_err_tips\n"
                exit 1
            }
            ss_method=$is_tmp_use_type
        fi
        [[ $is_use_pass ]] && ss_password=$is_use_pass && password=$is_use_pass
        [[ $is_use_host ]] && host=$is_use_host
        [[ $is_use_door_addr ]] && door_addr=$is_use_door_addr
        [[ $is_use_servername ]] && is_servername=$is_use_servername
        [[ $is_use_socks_user ]] && is_socks_user=$is_use_socks_user
        [[ $is_use_socks_pass ]] && is_socks_pass=$is_use_socks_pass
    fi

    if [[ ${is_new_protocol,,} == 'anytls' && $is_anytls_domain && ! $is_change && ! $is_gen ]]; then
        [[ $port && $port != 443 ]] && {
            err "AnyTLS ACME 域名模式固定使用 TCP 443。"
        }
        is_anytls_acme_mode=1
        is_anytls_acme_domain=$is_anytls_domain
        is_anytls_acme_port=443
        port=$is_anytls_acme_port
        preflight_anytls_acme
    fi

    if [[ $is_use_tls ]]; then
        if [[ ! $is_no_auto_tls && ! $is_caddy && ! $is_gen && ! $is_dont_test_host ]]; then
            # test auto tls
            [[ $(is_test port_used 80) || $(is_test port_used 443) ]] && {
                get_port
                is_http_port=$tmp_port
                get_port
                is_https_port=$tmp_port
                warn "端口 (80 或 443) 已经被占用, 你也可以考虑使用 no-auto-tls"
                msg "\e[41m no-auto-tls 帮助(help)\e[0m: 请使用 $is_core help 查看可用参数.\n"
                msg "\n Caddy 将使用非标准端口实现自动配置 TLS, HTTP:$is_http_port HTTPS:$is_https_port\n"
                msg "请确定是否继续???"
                pause
            }
            is_install_caddy=1
        fi
        # set host
        [[ ! $host ]] && ask string host "请输入域名:"
        # test host dns
        get host-test
    else
        # for main menu start, dont auto create args
        if [[ $is_main_start ]]; then

            # set port
            [[ ! $port ]] && ask string port "请输入端口:"

            case ${is_new_protocol,,} in
            socks)
                # set user
                [[ ! $is_socks_user ]] && ask string is_socks_user "请设置用户名:"
                # set password
                [[ ! $is_socks_pass ]] && ask string is_socks_pass "请设置密码:"
                ;;
            shadowsocks)
                # set method
                if [[ ! $ss_method ]]; then
                    ask set_ss_method || return 1
                fi
                # set password
                [[ ! $ss_password ]] && ask string ss_password "请设置密码:"
                ;;
            esac

        fi
    fi

    # Dokodemo-Door
    if [[ $is_new_protocol == 'Direct' ]]; then
        # set remote addr
        [[ ! $door_addr ]] && ask string door_addr "请输入目标地址:"
        # set remote port
        [[ ! $door_port ]] && ask string door_port "请输入目标端口:"
    fi

    # Shadowsocks 2022
    if [[ $(grep 2022 <<<$ss_method) ]]; then
        # test ss2022 password
        [[ $ss_password ]] && {
            is_test_json=1
            create server Shadowsocks
            [[ ! $tmp_uuid ]] && get_uuid
            is_test_json_save=$(mktemp "${TMPDIR:-/tmp}/sing-box-json-test.XXXXXX")
            cat <<<"$is_new_json" >$is_test_json_save
            $is_core_bin check -c $is_test_json_save &>/dev/null
            if [[ $? != 0 ]]; then
                warn "Shadowsocks 协议 ($ss_method) 不支持使用密码 ($(_red_bg $ss_password))\n\n你可以使用命令: $(_green $is_core ss2022) 生成支持的密码.\n\n脚本将自动创建可用密码:)"
                ss_password=
                # create new json.
                json_str=
            fi
            is_test_json=
            rm -f $is_test_json_save
        }

    fi

    # install caddy
    if [[ $is_install_caddy ]]; then
        get install-caddy
    fi

    # create json
    create server $is_new_protocol

    # show config info.
    info
}

# get config info
# or somes required args
get() {
    case $1 in
    addr)
        is_addr=$host
        [[ ! $is_addr ]] && {
            get_ip
            is_addr=$ip
            [[ $(grep ":" <<<$ip) ]] && is_addr="[$ip]"
        }
        ;;
    new)
        [[ ! $host ]] && get_ip
        [[ ! $port ]] && get_port && port=$tmp_port
        [[ ! $uuid ]] && get_uuid && uuid=$tmp_uuid
        ;;
    file)
        is_file_str=$2
        [[ ! $is_file_str ]] && is_file_str='.json$'
        # is_all_json=("$(ls $is_conf_dir | grep -E $is_file_str)")
        readarray -t is_all_json <<<"$(ls $is_conf_dir | grep -E -i "$is_file_str" | sed '/dynamic-port-.*-link/d' | head -233)" # limit max 233 lines for show.
        [[ ! $is_all_json ]] && err "无法找到相关的配置文件: $2"
        [[ ${#is_all_json[@]} -eq 1 ]] && is_config_file=$is_all_json && is_auto_get_config=1
        [[ ! $is_config_file ]] && {
            [[ $is_dont_auto_exit ]] && return
            ask get_config_file || return 1
        }
        ;;
    info)
        get file $2 || return 1
        if [[ $is_config_file ]]; then
            is_json_str=$(cat $is_conf_dir/"$is_config_file" | sed s#//.*##)
            is_json_data=$(jq '(.inbounds[0]|.type,.listen_port,(.users[0]|.uuid,.password,.username),.method,.password,.override_port,.override_address,(.transport|.type,.path,.headers.host),(.tls|.server_name,.reality.private_key)),(.outbounds[1].tag)' <<<$is_json_str)
            [[ $? != 0 ]] && err "无法读取此文件: $is_config_file"
            is_up_var_set=(null is_protocol port uuid password username ss_method ss_password door_port door_addr net_type path host is_servername is_private_key is_public_key)
            [[ $is_debug ]] && msg "\n------------- debug: $is_config_file -------------"
            i=0
            for v in $(sed 's/""/null/g;s/"//g' <<<"$is_json_data"); do
                ((i++))
                [[ $is_debug ]] && msg "$i-${is_up_var_set[$i]}: $v"
                export ${is_up_var_set[$i]}="${v}"
            done
            for v in ${is_up_var_set[@]}; do
                [[ ${!v} == 'null' ]] && unset $v
            done

            if [[ $is_private_key ]]; then
                is_reality=1
                net_type+=reality
                is_public_key=${is_public_key/public_key_/}
            fi
            is_socks_user=$username
            is_socks_pass=$password

            # extract anytls ACME domain
            [[ $is_protocol == 'anytls' ]] && {
                is_anytls_domain=$(jq -r '. as $root | ((($root.inbounds[0].tls.certificate_provider // empty) as $provider_tag | ($root.certificate_providers[]? | select(.tag == $provider_tag) | .domain[0])) // $root.inbounds[0].tls.acme.domain[0]) // empty' <<<$is_json_str 2>/dev/null)
            }

            is_config_name=$is_config_file

            if [[ $is_caddy && $host && -f $is_caddy_conf/$host.conf ]]; then
                is_tmp_https_port=$(grep -E -o "$host:[1-9][0-9]?+" $is_caddy_conf/$host.conf | sed s/.*://)
            fi
            if [[ $host && ! -f $is_caddy_conf/$host.conf ]]; then
                is_no_auto_tls=1
            fi
            [[ $is_tmp_https_port ]] && is_https_port=$is_tmp_https_port
            [[ $is_client && $host ]] && port=$is_https_port
            get protocol $is_protocol-$net_type
        fi
        ;;
    protocol)
        get addr # get host or server ip
        is_lower=${2,,}
        net=
        is_users="users:[{uuid:\"$uuid\"}]"
        is_tls_json='tls:{enabled:true,alpn:["h3"],key_path:"'$is_tls_key'",certificate_path:"'$is_tls_cer'"}'
        case $is_lower in
        vmess*)
            is_protocol=vmess
            [[ $is_lower =~ "tcp" || ! $net_type && $is_up_var_set ]] && net=tcp && json_str=$is_users
            ;;
        vless*)
            is_protocol=vless
            ;;
        tuic*)
            net=tuic
            is_protocol=$net
            [[ ! $password ]] && password=$uuid
            is_users="users:[{uuid:\"$uuid\",password:\"$password\"}]"
            json_str="$is_users,congestion_control:\"bbr\",$is_tls_json"
            ;;
        trojan*)
            is_protocol=trojan
            [[ ! $password ]] && password=$uuid
            is_users="users:[{password:\"$password\"}]"
            [[ ! $host ]] && {
                net=trojan
                json_str="$is_users,${is_tls_json/alpn\:\[\"h3\"\],/}"
            }
            ;;
        hysteria2*)
            net=hysteria2
            is_protocol=$net
            [[ ! $password ]] && password=$uuid
            json_str="users:[{password:\"$password\"}],$is_tls_json"
            ;;
        shadowsocks*)
            net=ss
            is_protocol=shadowsocks
            [[ ! $ss_method ]] && ss_method=$is_random_ss_method
            [[ ! $ss_password ]] && {
                ss_password=$uuid
                [[ $(grep 2022 <<<$ss_method) ]] && ss_password=$(get ss2022)
            }
            json_str="method:\"$ss_method\",password:\"$ss_password\""
            ;;
        direct*)
            net=direct
            is_protocol=$net
            json_str="override_port:$door_port,override_address:\"$door_addr\""
            ;;
        anytls*)
            net=anytls
            is_protocol=$net
            [[ ! $password ]] && password=$uuid
            is_users="users:[{password:\"$password\"}]"
            if [[ $is_anytls_domain ]]; then
                is_anytls_acme_domain=${is_anytls_acme_domain:-$is_anytls_domain}
                is_anytls_acme_data_dir=${is_anytls_acme_data_dir:-$is_core_dir/acme}
                if is_core_version_ge "$is_core_ver" "1.14.0"; then
                    is_anytls_acme_tag="acme-${is_anytls_acme_domain//[^A-Za-z0-9_.-]/-}"
                    is_anytls_tls="tls:{enabled:true,certificate_provider:\"$is_anytls_acme_tag\"}"
                    is_root_extra_json=",certificate_providers:[{type:\"acme\",tag:\"$is_anytls_acme_tag\",domain:[\"$is_anytls_acme_domain\"],data_directory:\"$is_anytls_acme_data_dir\"}]"
                else
                    is_anytls_tls="tls:{enabled:true,acme:{domain:[\"$is_anytls_acme_domain\"],data_directory:\"$is_anytls_acme_data_dir\"}}"
                fi
            else
                is_anytls_tls="${is_tls_json/alpn\:\[\"h3\"\],/}"
            fi
            json_str="$is_users,$is_anytls_tls"
            ;;
        socks*)
            net=socks
            is_protocol=$net
            [[ ! $is_socks_user ]] && is_socks_user=user
            [[ ! $is_socks_pass ]] && is_socks_pass=$uuid
            json_str="users:[{username: \"$is_socks_user\", password: \"$is_socks_pass\"}]"
            ;;
        *)
            err "无法识别协议: $is_config_file"
            ;;
        esac
        [[ $net ]] && return # if net exist, dont need more json args
        [[ $host && $is_lower =~ "tls" ]] && {
            [[ ! $path ]] && path="/$uuid"
            is_path_host_json=",path:\"$path\",headers:{host:\"$host\"}"
        }
        case $is_lower in
        *quic*)
            net=quic
            is_json_add="$is_tls_json,transport:{type:\"$net\"}"
            ;;
        *ws*)
            net=ws
            is_json_add="transport:{type:\"$net\"$is_path_host_json,early_data_header_name:\"Sec-WebSocket-Protocol\"}"
            ;;
        *reality*)
            net=reality
            [[ ! $is_servername ]] && is_servername=$is_random_servername
            [[ ! $is_private_key ]] && get_pbk
            is_json_add="tls:{enabled:true,server_name:\"$is_servername\",reality:{enabled:true,handshake:{server:\"$is_servername\",server_port:443},private_key:\"$is_private_key\",short_id:[\"\"]}}"
            [[ $is_lower =~ "http" ]] && {
                is_json_add="$is_json_add,transport:{type:\"http\"}"
            } || {
                is_users=${is_users/uuid/flow:\"xtls-rprx-vision\",uuid}
            }
            ;;
        *http* | *h2*)
            net=http
            [[ $is_lower =~ "up" ]] && net=httpupgrade
            is_json_add="transport:{type:\"$net\"$is_path_host_json}"
            [[ $is_lower =~ "h2" || ! $is_lower =~ "httpupgrade" && $host ]] && {
                net=h2
                is_json_add="${is_tls_json/alpn\:\[\"h3\"\],/},$is_json_add"
            }
            ;;
        *)
            err "无法识别传输协议: $is_config_file"
            ;;
        esac
        json_str="$is_users,$is_json_add"
        ;;
    host-test) # test host dns record; for auto *tls required.
        [[ $is_no_auto_tls || $is_gen || $is_dont_test_host ]] && return
        get_ip
        get ping
        if [[ ! $(grep $ip <<<$is_host_dns) ]]; then
            msg "\n请将 ($(_red_bg $host)) 解析到 ($(_red_bg $ip))"
            msg "\n如果使用 Cloudflare, 在 DNS 那; 关闭 (Proxy status / 代理状态), 即是 (DNS only / 仅限 DNS)"
            ask string y "我已经确定解析 [y]:"
            get ping
            if [[ ! $(grep $ip <<<$is_host_dns) ]]; then
                _cyan "\n测试结果: $is_host_dns"
                err "域名 ($host) 没有解析到 ($ip)"
            fi
        fi
        ;;
    ssss | ss2022)
        if [[ $(grep 128 <<<$ss_method) ]]; then
            $is_core_bin generate rand 16 --base64
        else
            $is_core_bin generate rand 32 --base64
        fi
        ;;
    ping)
        # is_ip_type="-4"
        # [[ $(grep ":" <<<$ip) ]] && is_ip_type="-6"
        # is_host_dns=$(ping $host $is_ip_type -c 1 -W 2 | head -1)
        is_dns_type="a"
        [[ $(grep ":" <<<$ip) ]] && is_dns_type="aaaa"
        is_host_dns=$(_wget -qO- --header="accept: application/dns-json" "https://one.one.one.one/dns-query?name=$host&type=$is_dns_type")
        ;;
    install-caddy)
        _green "\n安装 Caddy 实现自动配置 TLS.\n"
        load download.sh
        download caddy
        load systemd.sh
        install_service caddy &>/dev/null
        is_caddy=1
        _green "安装 Caddy 成功.\n"
        ;;
    reinstall)
        is_install_sh=$(cat $is_sh_dir/install.sh)
        uninstall
        bash <<<$is_install_sh
        ;;
    test-run)
        if [[ $is_systemd ]]; then
            systemctl list-units --full -all &>/dev/null
            [[ $? != 0 ]] && {
                _yellow "\n无法执行测试, 请检查 systemctl 状态.\n"
                return
            }
        fi
        is_no_manage_msg=1
        if [[ ! $(pgrep -f $is_core_bin 2>/dev/null || grep -l "$is_core_bin" /proc/*/cmdline 2>/dev/null) ]]; then
            _yellow "\n测试运行 $is_core_name ..\n"
            manage start &>/dev/null
            if [[ $is_run_fail == $is_core ]]; then
                _red "$is_core_name 运行失败信息:"
                $is_core_bin run -c $is_config_json -C $is_conf_dir
            else
                _green "\n测试通过, 已启动 $is_core_name ..\n"
            fi
        else
            _green "\n$is_core_name 正在运行, 跳过测试\n"
        fi
        if [[ $is_caddy ]]; then
            if [[ ! $(pgrep -f $is_caddy_bin 2>/dev/null || grep -l "$is_caddy_bin" /proc/*/cmdline 2>/dev/null) ]]; then
                _yellow "\n测试运行 Caddy ..\n"
                manage start caddy &>/dev/null
                if [[ $is_run_fail == 'caddy' ]]; then
                    _red "Caddy 运行失败信息:"
                    $is_caddy_bin run --config $is_caddyfile
                else
                    _green "\n测试通过, 已启动 Caddy ..\n"
                fi
            else
                _green "\nCaddy 正在运行, 跳过测试\n"
            fi
        fi
        ;;
    esac
}

# show info
info() {
    if [[ ! $is_protocol ]]; then
        get info $1 || return 1
    fi
    # is_color=$(shuf -i 41-45 -n1)
    is_color=44
    case $net in
    ws | tcp | h2 | quic | http*)
        if [[ $host ]]; then
            is_color=45
            is_can_change=(0 1 2 3 5)
            is_info_show=(0 1 2 3 4 6 7 8)
            [[ $is_protocol == 'vmess' ]] && {
                is_vmess_url=$(jq -c '{v:2,ps:'\"$is_core_name-$net-$host\"',add:'\"$is_addr\"',port:'\"$is_https_port\"',id:'\"$uuid\"',aid:"0",net:'\"$net\"',host:'\"$host\"',path:'\"$path\"',tls:'\"tls\"'}' <<<{})
                is_url=vmess://$(echo -n $is_vmess_url | base64 -w 0)
            } || {
                [[ $is_protocol == "trojan" ]] && {
                    uuid=$password
                    # is_info_str=($is_protocol $is_addr $is_https_port $password $net $host $path 'tls')
                    is_can_change=(0 1 2 3 4)
                    is_info_show=(0 1 2 10 4 6 7 8)
                }
                is_url="$is_protocol://$uuid@$host:$is_https_port?encryption=none&security=tls&type=$net&host=$host&path=$path#$is_core_name-$net-$host"
            }
            [[ $is_caddy ]] && is_can_change+=(11)
            is_info_str=($is_protocol $is_addr $is_https_port $uuid $net $host $path 'tls')
        else
            is_type=none
            is_can_change=(0 1 5)
            is_info_show=(0 1 2 3 4)
            is_info_str=($is_protocol $is_addr $port $uuid $net)
            [[ $net == "http" ]] && {
                net=tcp
                is_type=http
                is_tcp_http=1
                is_info_show+=(5)
                is_info_str=(${is_info_str[@]/http/tcp http})
            }
            [[ $net == "quic" ]] && {
                is_insecure=1
                is_info_show+=(8 9 20)
                is_info_str+=(tls h3 true)
                is_quic_add=",tls:\"tls\",alpn:\"h3\"" # cant add allowInsecure
            }
            is_vmess_url=$(jq -c "{v:2,ps:\"$is_core_name-${net}-$is_addr\",add:\"$is_addr\",port:\"$port\",id:\"$uuid\",aid:\"0\",net:\"$net\",type:\"$is_type\"$is_quic_add}" <<<{})
            is_url=vmess://$(echo -n $is_vmess_url | base64 -w 0)
        fi
        ;;
    ss)
        is_can_change=(0 1 4 6)
        is_info_show=(0 1 2 10 11)
        is_url="ss://$(echo -n ${ss_method}:${ss_password} | base64 -w 0)@${is_addr}:${port}#$is_core_name-$net-${is_addr}"
        is_info_str=($is_protocol $is_addr $port $ss_password $ss_method)
        ;;
    trojan)
        is_insecure=1
        is_can_change=(0 1 4)
        is_info_show=(0 1 2 10 4 8 20)
        is_url="$is_protocol://$password@$is_addr:$port?type=tcp&security=tls&allowInsecure=1#$is_core_name-$net-$is_addr"
        is_info_str=($is_protocol $is_addr $port $password tcp tls true)
        ;;
    hy*)
        is_can_change=(0 1 4)
        is_info_show=(0 1 2 10 8 9 20)
        is_url="$is_protocol://$password@$is_addr:$port?alpn=h3&insecure=1#$is_core_name-$net-$is_addr"
        is_info_str=($is_protocol $is_addr $port $password tls h3 true)
        ;;
    tuic)
        is_insecure=1
        is_can_change=(0 1 4 5)
        is_info_show=(0 1 2 3 10 8 9 20 21)
        is_url="$is_protocol://$uuid:$password@$is_addr:$port?alpn=h3&allow_insecure=1&congestion_control=bbr#$is_core_name-$net-$is_addr"
        is_info_str=($is_protocol $is_addr $port $uuid $password tls h3 true bbr)
        ;;
    reality)
        is_color=41
        is_can_change=(0 1 5 9 10)
        is_info_show=(0 1 2 3 15 4 8 16 17 18)
        is_flow=xtls-rprx-vision
        is_net_type=tcp
        [[ $net_type =~ "http" || ${is_new_protocol,,} =~ "http" ]] && {
            is_flow=
            is_net_type=h2
            is_info_show=(${is_info_show[@]/15/})
        }
        is_info_str=($is_protocol $is_addr $port $uuid $is_flow $is_net_type reality $is_servername chrome $is_public_key)
        is_url="$is_protocol://$uuid@$is_addr:$port?encryption=none&security=reality&flow=$is_flow&type=$is_net_type&sni=$is_servername&pbk=$is_public_key&fp=chrome#$is_core_name-$net-$is_addr"
        ;;
    anytls)
        is_can_change=(0 1 4)
        if [[ $is_anytls_domain ]]; then
            is_info_show=(0 1 2 10 8)
            is_info_str=($is_protocol $is_anytls_domain $port $password tls)
            is_url="anytls://$password@$is_anytls_domain:$port#$is_core_name-$net-$is_anytls_domain"
        else
            is_insecure=1
            is_info_show=(0 1 2 10 8 20)
            is_info_str=($is_protocol $is_addr $port $password tls true)
            is_url="anytls://$password@$is_addr:$port?allowInsecure=1#$is_core_name-$net-$is_addr"
        fi
        ;;
    direct)
        is_can_change=(0 1 7 8)
        is_info_show=(0 1 2 13 14)
        is_info_str=($is_protocol $is_addr $port $door_addr $door_port)
        ;;
    socks)
        is_can_change=(0 1 12 4)
        is_info_show=(0 1 2 19 10)
        is_info_str=($is_protocol $is_addr $port $is_socks_user $is_socks_pass)
        is_url="socks://$(echo -n ${is_socks_user}:${is_socks_pass} | base64 -w 0)@${is_addr}:${port}#$is_core_name-$net-${is_addr}"
        ;;
    esac
    [[ $is_dont_show_info || $is_gen || $is_dont_auto_exit ]] && return # dont show info
    msg "-------------- $is_config_name -------------"
    for ((i = 0; i < ${#is_info_show[@]}; i++)); do
        a=${info_list[${is_info_show[$i]}]}
        if [[ ${#a} -eq 11 || ${#a} -ge 13 ]]; then
            tt='\t'
        else
            tt='\t\t'
        fi
        msg "$a $tt= \e[${is_color}m${is_info_str[$i]}\e[0m"
    done
    if [[ $is_new_install ]]; then
        warn "首次安装请查看脚本帮助: $is_core help"
    fi
    if [[ $is_url ]]; then
        msg "------------- ${info_list[12]} -------------"
        msg "\e[4;${is_color}m${is_url}\e[0m"
        [[ $is_insecure ]] && {
            warn "某些客户端如(V2rayN 等)导入URL需手动将: 跳过证书验证(allowInsecure) 设置为 true, 或打开: 允许不安全的连接"
        }
    fi
    if [[ $is_no_auto_tls ]]; then
        msg "------------- no-auto-tls INFO -------------"
        msg "端口(port): $port"
        msg "路径(path): $path"
        msg "\e[41m帮助(help)\e[0m: $is_core help"
    fi
    footer_msg
}

# footer msg
footer_msg() {
    [[ $is_core_stop && ! $is_new_json ]] && warn "$is_core_name 当前处于停止状态."
    [[ $is_caddy_stop && $host ]] && warn "Caddy 当前处于停止状态."
    ####### 要点13脸吗只会改我链接的小人 #######
    unset c n m s b
    msg "------------- END -------------"
    msg
    ####### 要点13脸吗只会改我链接的小人 #######
}

# URL or qrcode
url_qr() {
    is_dont_show_info=1
    info $2
    if [[ $is_url ]]; then
        [[ $1 == 'url' ]] && {
            msg "\n------------- $is_config_name & URL 链接 -------------"
            msg "\n\e[${is_color}m${is_url}\e[0m\n"
            footer_msg
        } || {
            msg "\n------------- $is_config_name & QR code 二维码 -------------"
            msg
            if [[ $(type -P qrencode) ]]; then
                qrencode -t ANSI "${is_url}"
            else
                msg "请安装 qrencode: $(_green "$cmd update -y; $cmd install qrencode -y")"
            fi
            msg
            footer_msg
        }
    else
        [[ $1 == 'url' ]] && {
            err "($is_config_name) 无法生成 URL 链接."
        } || {
            err "($is_config_name) 无法生成 QR code 二维码."
        }
    fi
}

# update core, sh, caddy
update() {
    is_update_target=$1
    shift || true
    unset is_new_ver is_update_backup_finalize

    case $is_update_target in
    1 | core | $is_core)
        is_update_name=core
        is_show_name=$is_core_name
        is_run_ver=v${is_core_ver##* }
        is_update_repo=$is_core_repo
        ;;
    2 | sh)
        is_update_name=sh
        is_show_name="$is_core_name 脚本"
        is_run_ver=$is_sh_ver
        is_update_repo=$is_sh_repo
        ;;
    3 | caddy)
        [[ ! $is_caddy ]] && err "不支持更新 Caddy."
        is_update_name=caddy
        is_show_name="Caddy"
        is_run_ver=$is_caddy_ver
        is_update_repo=$is_caddy_repo
        ;;
    *)
        err "无法识别 ($is_update_target), 请使用: $is_core update [core | sh | caddy] [ver | --latest]"
        ;;
    esac
    load download.sh

    if [[ $is_update_name == core ]]; then
        parse_core_version_policy_args "$@" || return 1
        is_new_ver=$(resolve_core_version_policy "$VERSION_POLICY_REQUESTED_VERSION" "$VERSION_POLICY_USE_LATEST") || return 1
        [[ $is_run_ver == $is_new_ver ]] && {
            msg "\n$is_show_name 当前已经是目标版本 ($is_new_ver), 无需更新.\n"
            return 0
        }
        if [[ $VERSION_POLICY_REQUESTED_VERSION ]]; then
            msg "\n使用自定义版本更新 $is_show_name: $(_green $is_new_ver)\n"
        elif [[ $VERSION_POLICY_USE_LATEST == true ]]; then
            msg "\n发现 $is_show_name latest 版本: $(_green $is_new_ver)\n"
        else
            msg "\n使用 pinned stable 版本更新 $is_show_name: $(_green $is_new_ver)\n"
        fi
    else
        [[ $1 ]] && is_new_ver=v${1#v}
        [[ $is_run_ver == $is_new_ver ]] && {
            msg "\n自定义版本和当前 $is_show_name 版本一样, 无需更新.\n"
            return 0
        }
        if [[ $is_new_ver ]]; then
            msg "\n使用自定义版本更新 $is_show_name: $(_green $is_new_ver)\n"
        else
            get_latest_version $is_update_name
            [[ $is_run_ver == $latest_ver ]] && {
                msg "\n$is_show_name 当前已经是最新版本了.\n"
                return 0
            }
            msg "\n发现 $is_show_name 新版本: $(_green $latest_ver)\n"
            is_new_ver=$latest_ver
        fi
    fi
    begin_backup_transaction_if_needed "update-$is_update_name" && is_update_backup_finalize=1
    download $is_update_name $is_new_ver
    [[ $is_update_backup_finalize ]] && finalize_backup_transaction && unset is_update_backup_finalize
    msg "更新成功, 当前 $is_show_name 版本: $(_green $is_new_ver)\n"
    msg "$(_green 请查看更新说明: https://github.com/$is_update_repo/releases/tag/$is_new_ver)\n"
    [[ $is_update_name != 'sh' ]] && manage restart $is_update_name &
}

reset_menu_action_state() {
    unset REPLY is_main_pick is_do_manage is_do_update is_do_other is_do_uninstall
    unset is_menu_back is_menu_exit is_config_file is_auto_get_config is_all_json
    unset is_new_protocol is_lower is_add_opts is_err_tips is_set_new_protocol is_old_net
    unset is_change is_change_id is_change_str is_change_msg is_auto is_try_change
    unset is_new_port is_new_host is_new_path is_new_pass is_new_uuid is_new_method
    unset is_new_door_addr is_new_door_port is_new_private_key is_new_public_key
    unset is_new_servername is_new_proxy_site proxy_site old_host
    unset is_use_tls is_use_port is_use_uuid is_use_host is_use_path is_use_pass
    unset is_use_method is_use_door_addr is_use_door_port is_use_servername
    unset is_use_socks_user is_use_socks_pass is_main_anytls_acme is_anytls_cert
    unset is_anytls_domain is_anytls_acme_mode is_anytls_acme_domain is_anytls_acme_port
    unset is_anytls_acme_tag is_anytls_acme_data_dir is_root_extra_json
    unset is_install_caddy is_no_auto_tls is_dont_show_info is_skip_config_restart
    unset is_dont_get_ip is_no_del_msg is_del_host is_conf_dir_empty is_client
    unset is_test_json is_new_json is_json_add is_add_public_key json_str
    unset is_config_name is_json_file is_protocol is_listen is_tls net net_type
    unset host path port uuid password username ss_method ss_password door_port door_addr
    unset is_servername is_private_key is_public_key is_socks is_socks_user is_socks_pass
    unset is_info_show is_info_str is_url is_insecure is_color is_type is_tcp_http
}

status_to_text() {
    case $1 in
    *running* | *active* | *RUNNING* | *ACTIVE*)
        printf '%s' "active"
        ;;
    *stopped* | *inactive* | *STOPPED* | *INACTIVE*)
        printf '%s' "inactive"
        ;;
    *missing* | *MISSING*)
        printf '%s' "missing"
        ;;
    *)
        printf '%s' "unknown"
        ;;
    esac
}

get_core_status_text() {
    if [[ ${is_core_status:-} ]]; then
        status_to_text "$is_core_status"
        return
    fi
    if [[ ${is_core_bin:-} && $(pgrep -f "$is_core_bin" 2>/dev/null || grep -l "$is_core_bin" /proc/*/cmdline 2>/dev/null) ]]; then
        printf '%s' "active"
    elif [[ ${is_core_stop:-} ]]; then
        printf '%s' "inactive"
    else
        printf '%s' "unknown"
    fi
}

get_caddy_status_text() {
    if [[ ${is_caddy_status:-} ]]; then
        status_to_text "$is_caddy_status"
        return
    fi
    if [[ ! ${is_caddy:-} ]]; then
        printf '%s' "inactive"
        return
    fi
    if [[ ${is_caddy_bin:-} && $(pgrep -f "$is_caddy_bin" 2>/dev/null || grep -l "$is_caddy_bin" /proc/*/cmdline 2>/dev/null) ]]; then
        printf '%s' "active"
    elif [[ ${is_caddy_stop:-} ]]; then
        printf '%s' "inactive"
    else
        printf '%s' "unknown"
    fi
}

get_manager_text() {
    if [[ ${is_systemd:-} ]]; then
        printf '%s' "systemd"
    elif [[ ${is_openrc:-} ]]; then
        printf '%s' "openrc"
    else
        printf '%s' "unknown"
    fi
}

build_main_status_line() {
    printf '%s: %s | Core: %s | Caddy: %s | Manager: %s' \
        "${is_core_name:-sing-box}" \
        "$(get_core_status_text)" \
        "${is_core_ver:-unknown}" \
        "$(get_caddy_status_text)" \
        "$(get_manager_text)"
}

# main menu; if no prefer args.
is_main_menu() {
    is_main_start=1
    while :; do
        reset_menu_action_state
        ui_blank
        ui_title "sing-box 管理脚本" "$is_sh_ver"
        ui_dim "$(build_main_status_line)"
        ask mainmenu || {
            [[ ${is_menu_exit:-} ]] && break
            continue
        }
        case $REPLY in
        1)
            run_with_backup_transaction add add
            [[ ${is_menu_back:-} ]] && continue
            ;;
        2)
            run_with_backup_transaction change change
            [[ ${is_menu_back:-} ]] && continue
            ;;
        3)
            info
            [[ ${is_menu_back:-} ]] && continue
            ;;
        4)
            run_with_backup_transaction delete del
            [[ ${is_menu_back:-} ]] && continue
            ;;
        5)
            ask list is_do_manage "启动 停止 重启" || continue
            manage $REPLY &
            msg "\n管理状态执行: $(_green $is_do_manage)\n"
            ;;
        6)
            is_tmp_list=("更新$is_core_name" "更新脚本")
            [[ $is_caddy ]] && is_tmp_list+=("更新Caddy")
            ask list is_do_update null "\n请选择更新:\n" || continue
            update $REPLY
            ;;
        7)
            run_with_backup_transaction uninstall uninstall
            [[ ${is_menu_back:-} ]] && continue
            break
            ;;
        8)
            msg
            load help.sh
            show_help
            ;;
        9)
            ask list is_do_other "启用BBR 查看日志 测试运行 重装脚本 设置DNS" || continue
            case $REPLY in
            1)
                load bbr.sh
                _try_enable_bbr
                ;;
            2)
                load log.sh
                log_set
                ;;
            3)
                get test-run
                ;;
            4)
                run_with_backup_transaction reinstall get reinstall
                break
                ;;
            5)
                load dns.sh
                dns_set
                [[ ${is_menu_back:-} ]] && continue
                ;;
            esac
            ;;
        10)
            load help.sh
            about
            ;;
        esac
        pause
    done
}

# check prefer args, if not exist prefer args and show main menu
main() {
    case $1 in
    a | add | gen | no-auto-tls)
        [[ $1 == 'gen' ]] && is_gen=1
        [[ $1 == 'no-auto-tls' ]] && is_no_auto_tls=1
        if [[ $is_gen ]]; then
            add ${@:2}
        else
            run_with_backup_transaction add add ${@:2}
        fi
        ;;
    bin | pbk | check | completion | format | generate | geoip | geosite | merge | rule-set | run | tools)
        is_run_command=$1
        if [[ $1 == 'bin' ]]; then
            $is_core_bin ${@:2}
        else
            [[ $is_run_command == 'pbk' ]] && is_run_command="generate reality-keypair"
            $is_core_bin $is_run_command ${@:2}
        fi
        ;;
    bbr)
        load bbr.sh
        _try_enable_bbr
        ;;
    c | config | change)
        run_with_backup_transaction change change ${@:2}
        ;;
    # client | genc)
    #     create client $2
    #     ;;
    d | del | rm)
        run_with_backup_transaction delete del $2
        ;;
    dd | ddel | fix | fix-all)
        begin_backup_transaction_if_needed "$1" && is_bulk_backup_finalize=1
        case $1 in
        fix)
            [[ $2 ]] && {
                change $2 full
            } || {
                is_change_id=full && change
            }
            [[ $is_bulk_backup_finalize ]] && finalize_backup_transaction && unset is_bulk_backup_finalize
            return
            ;;
        fix-all)
            is_dont_auto_exit=1
            msg
            for v in $(ls $is_conf_dir | grep .json$ | sed '/dynamic-port-.*-link/d'); do
                msg "fix: $v"
                change $v full
            done
            _green "\nfix 完成.\n"
            ;;
        *)
            is_dont_auto_exit=1
            [[ ! $2 ]] && {
                err "无法找到需要删除的参数"
            } || {
                for v in ${@:2}; do
                    del $v
                done
            }
            ;;
        esac
        is_dont_auto_exit=
        manage restart &
        [[ $is_del_host ]] && manage restart caddy &
        [[ $is_bulk_backup_finalize ]] && finalize_backup_transaction && unset is_bulk_backup_finalize
        ;;
    dns)
        load dns.sh
        dns_set ${@:2}
        ;;
    debug)
        is_debug=1
        get info $2
        warn "如果需要复制; 请把 *uuid, *password, *host, *key 的值改写, 以避免泄露."
        ;;
    fix-config.json)
        run_with_backup_transaction fix-config create config.json
        ;;
    fix-caddyfile)
        if [[ $is_caddy ]]; then
            load caddy.sh
            run_with_backup_transaction fix-caddy caddy_config new
            manage restart caddy &
            _green "\nfix 完成.\n"
        else
            err "无法执行此操作"
        fi
        ;;
    i | info)
        info $2
        ;;
    ip)
        get_ip
        msg $ip
        ;;
    in | import)
        load import.sh
        ;;
    log)
        load log.sh
        log_set $2
        ;;
    url | qr)
        url_qr $@
        ;;
    un | uninstall)
        run_with_backup_transaction uninstall uninstall
        ;;
    rollback)
        rollback_latest_backup ${@:2}
        ;;
    u | up | update | U | update.sh)
        is_update_name=$2
        [[ ! $is_update_name ]] && is_update_name=core
        [[ $1 == 'U' || $1 == 'update.sh' ]] && {
            is_update_name=sh
            update "$is_update_name"
            return
        }
        update "$is_update_name" "${@:3}"
        ;;
    ssss | ss2022)
        get $@
        ;;
    s | status)
        msg "\n$is_core_name $is_core_ver: $is_core_status\n"
        [[ $is_caddy ]] && msg "Caddy $is_caddy_ver: $is_caddy_status\n"
        ;;
    start | stop | r | restart)
        [[ $2 && $2 != 'caddy' ]] && err "无法识别 ($2), 请使用: $is_core $1 [caddy]"
        manage $1 $2 &
        ;;
    t | test)
        get test-run
        ;;
    reinstall)
        get $1
        ;;
    get-port)
        get_port
        msg $tmp_port
        ;;
    main)
        is_main_menu
        ;;
    v | ver | version)
        [[ $is_caddy_ver ]] && is_caddy_ver="/ $(_blue Caddy $is_caddy_ver)"
        msg "\n$(_green $is_core_name $is_core_ver) / $(_cyan $is_core_name script $is_sh_ver) $is_caddy_ver\n"
        ;;
    h | help | --help)
        load help.sh
        show_help ${@:2}
        ;;
    *)
        is_try_change=1
        change test $1
        if [[ $is_change_id ]]; then
            unset is_try_change
            [[ $2 ]] && {
                change $2 $1 ${@:3}
            } || {
                change
            }
        else
            err "无法识别 ($1), 获取帮助请使用: $is_core help"
        fi
        ;;
    esac
}
