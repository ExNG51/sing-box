#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sing-box-ask-style.XXXXXX")"
ASK_SNIPPET="$TMP_DIR/ask-snippet.sh"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_match() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$file" >/dev/null || fail "$description"
    else
        grep -En "$pattern" "$file" >/dev/null || fail "$description"
    fi
}

assert_no_match() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        if rg -n "$pattern" "$file" >/dev/null; then
            fail "$description"
        fi
    else
        if grep -En "$pattern" "$file" >/dev/null; then
            fail "$description"
        fi
    fi
}

assert_contains() {
    local text=$1
    local file=$2
    local description=$3

    grep -Fq -- "$text" "$file" || fail "$description"
}

assert_not_contains() {
    local text=$1
    local file=$2
    local description=$3

    if grep -Fq -- "$text" "$file"; then
        fail "$description"
    fi
}

run_with_timeout() {
    local seconds=$1
    shift

    perl -e '
        my $seconds = shift @ARGV;
        my $pid;
        $SIG{ALRM} = sub {
            if ($pid) {
                kill "TERM", $pid;
                sleep 1;
                kill "KILL", $pid;
            }
            exit 124;
        };
        $pid = fork();
        die "fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            exec @ARGV or exit 127;
        }
        alarm $seconds;
        waitpid($pid, 0);
        exit($? >> 8);
    ' "$seconds" "$@"
}

sed -n '/^ask()/,/^}/p' "$REPO_ROOT/src/core.sh" >"$ASK_SNIPPET"

for file in sing-box.sh src/*.sh tests/*.sh; do
    [[ -e $REPO_ROOT/$file ]] || continue
    bash -n "$REPO_ROOT/$file"
done

assert_not_contains '\e[91m' "$ASK_SNIPPET" \
    'ask() prompt/output fragment must not contain hardcoded red ANSI'
assert_not_contains '\e[92m' "$ASK_SNIPPET" \
    'ask() prompt/output fragment must not contain hardcoded green ANSI'
assert_not_contains '\e[0m' "$ASK_SNIPPET" \
    'ask() prompt/output fragment must not contain hardcoded reset ANSI'

assert_contains 'read REPLY' "$ASK_SNIPPET" \
    'ask() must still read input through read REPLY'
assert_not_contains 'ui_read_raw' "$ASK_SNIPPET" \
    'ask() must not introduce ui_read_raw'
assert_not_contains 'ui_read_or_cancel' "$ASK_SNIPPET" \
    'ask() must not introduce ui_read_or_cancel'
assert_not_contains '/dev/tty' "$ASK_SNIPPET" \
    'ask() must not switch to /dev/tty input'

assert_contains 'is_ask_result=${is_tmp_list[$REPLY - 1]}' "$ASK_SNIPPET" \
    'ask() must keep list selection mapping semantics'
assert_contains 'export $is_ask_set="$is_ask_result"' "$ASK_SNIPPET" \
    'ask() must keep exporting selected list values'
assert_contains 'export $is_ask_set=$is_default_arg' "$ASK_SNIPPET" \
    'ask() must keep default value export semantics'
assert_match 'case \$REPLY in' "$REPO_ROOT/src/core.sh" \
    'main menu must still dispatch on REPLY'

assert_contains 'is_menu_exit=1' "$ASK_SNIPPET" \
    'ask() must still set is_menu_exit'
assert_contains 'is_menu_back=1' "$ASK_SNIPPET" \
    'ask() must still set is_menu_back'
assert_contains 'is_emtpy_exit' "$ASK_SNIPPET" \
    'ask() must still keep is_emtpy_exit control flow'
assert_contains 'ask_cleanup' "$ASK_SNIPPET" \
    'ask() must still call ask_cleanup'
assert_contains 'return 1' "$ASK_SNIPPET" \
    'ask() must still return 1 on menu exit/back paths'

assert_contains 'is_test port ' "$ASK_SNIPPET" \
    'ask() must still validate ports'
assert_contains 'is_test port_used' "$ASK_SNIPPET" \
    'ask() must still validate used ports'
assert_contains 'is_test path ' "$ASK_SNIPPET" \
    'ask() must still validate paths'
assert_contains 'is_test uuid ' "$ASK_SNIPPET" \
    'ask() must still validate UUID values'
assert_contains 'is_test domain ' "$ASK_SNIPPET" \
    'ask() must still validate domains'
assert_contains "is_ask_set == 'is_anytls_domain'" "$ASK_SNIPPET" \
    'ask() must still special-case AnyTLS domain validation'

assert_contains 'ui_error ' "$ASK_SNIPPET" \
    'ask() must use ui_error for validation failures'
assert_contains 'ui_info ' "$ASK_SNIPPET" \
    'ask() must use ui_info for selection/use/back prompts'
assert_contains 'ui_print_inline "$is_opt_input_msg"' "$ASK_SNIPPET" \
    'ask() must keep inline prompt output'

assert_match 'commit_server_config_with_validation' "$REPO_ROOT/src/core.sh" \
    'AnyTLS transactional config path must remain present'
assert_match '^preflight_anytls_acme\(\)' "$REPO_ROOT/src/core.sh" \
    'preflight_anytls_acme must remain present'
assert_contains 'is_anytls_acme_port=443' "$REPO_ROOT/src/core.sh" \
    'AnyTLS ACME must keep TCP 443'
assert_match '^info\(\)' "$REPO_ROOT/src/core.sh" \
    'info output path must remain present'
assert_match '^url_qr\(\)' "$REPO_ROOT/src/core.sh" \
    'url/qr output path must remain present'

assert_match '^is_sh_ver=v1\.21$' "$REPO_ROOT/sing-box.sh" \
    'sing-box.sh must bump the manager version to v1.21'

default_output="$TMP_DIR/default.out"
if ! run_with_timeout 3 bash -c '
    set -euo pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"

    ui_print() { printf "%b\n" "$*"; }
    ui_print_inline() { printf "%b" "$*"; }
    ui_blank() { printf "\n"; }
    ui_info() { printf "[i] %s\n" "$*"; }
    ui_error() { printf "[ERROR] %s\n" "$*" >&2; }
    ui_menu_item() { printf " %2s. %s\n" "$1" "$2"; }
    show_list() { :; }
    ask_cleanup() { :; }
    _green() { printf "%s" "$*"; }

    is_main_start=
    is_emtpy_exit=
    ask set_anytls_cert < <(printf "\n")
    printf "status=%s\n" "$?"
    printf "is_anytls_cert=%s\n" "${is_anytls_cert:-unset}"
' bash "$REPO_ROOT" >"$default_output" 2>&1; then
    cat "$default_output" >&2
    fail 'ask() must keep default-value selection behavior'
fi

assert_contains 'status=0' "$default_output" \
    'empty input must keep successful ask() status when default is available'
assert_contains 'is_anytls_cert=yes' "$default_output" \
    'empty input must still select the default AnyTLS certificate option'

back_output="$TMP_DIR/back.out"
if ! run_with_timeout 3 bash -c '
    set -uo pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"

    ui_print() { printf "%b\n" "$*"; }
    ui_print_inline() { printf "%b" "$*"; }
    ui_blank() { printf "\n"; }
    ui_info() { printf "[i] %s\n" "$*"; }
    ui_error() { printf "[ERROR] %s\n" "$*" >&2; }
    ui_menu_item() { printf " %2s. %s\n" "$1" "$2"; }
    show_list() { :; }
    ask_cleanup() { :; }

    is_main_start=1
    ask list is_do_manage "启动 停止 重启" "\n请选择管理操作:\n" < <(printf "0\n")
    status=$?
    printf "status=%s\n" "$status"
    printf "is_menu_back=%s\n" "${is_menu_back:-unset}"
    printf "is_do_manage=%s\n" "${is_do_manage:-unset}"
' bash "$REPO_ROOT" >"$back_output" 2>&1; then
    cat "$back_output" >&2
    fail 'ask() submenu lists must still treat 0 as menu-back'
fi

assert_contains 'status=1' "$back_output" \
    'submenu list input 0 must keep the non-zero return status'
assert_contains 'is_menu_back=1' "$back_output" \
    'submenu list input 0 must still mark a menu-back request'
assert_contains 'is_do_manage=unset' "$back_output" \
    'submenu list input 0 must not pick a list action'
assert_contains '[i] 返回主菜单。' "$back_output" \
    'submenu list input 0 must still emit the informational back message'

port_output="$TMP_DIR/port.out"
if ! run_with_timeout 3 bash -c '
    set -euo pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"

    ui_print() { printf "%b\n" "$*"; }
    ui_print_inline() { printf "%b" "$*"; }
    ui_blank() { printf "\n"; }
    ui_info() { printf "[i] %s\n" "$*"; }
    ui_error() { printf "[ERROR] %s\n" "$*" >&2; }
    ask_cleanup() { :; }

    is_main_start=
    is_emtpy_exit=
    ask string door_port "请输入目标端口:" < <(printf "70000\n443\n")
    printf "status=%s\n" "$?"
    printf "door_port=%s\n" "${door_port:-unset}"
' bash "$REPO_ROOT" >"$port_output" 2>&1; then
    cat "$port_output" >&2
    fail 'ask() port validation must continue prompting until a valid port is provided'
fi

assert_contains '[ERROR] 请输入正确的端口，可选范围：1-65535。' "$port_output" \
    'invalid ports must still report the unified error style before retrying'
assert_contains 'status=0' "$port_output" \
    'port retry flow must still complete successfully after valid input'
assert_contains 'door_port=443' "$port_output" \
    'port retry flow must still export the accepted port value'

printf '[PASS] ask output style checks\n'
