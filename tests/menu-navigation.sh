#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_count() {
    local pattern=$1
    local expected=$2
    local file=$3
    local description=$4
    local actual

    actual=$(grep -Ec "$pattern" "$file" || true)
    [[ $actual == "$expected" ]] || {
        cat "$file" >&2
        fail "$description (expected $expected, got $actual)"
    }
}

assert_contains() {
    local pattern=$1
    local file=$2
    local description=$3

    grep -Eq "$pattern" "$file" || {
        cat "$file" >&2
        fail "$description"
    }
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

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sing-box-menu-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

for file in install.sh sing-box.sh src/*.sh; do
    bash -n "$REPO_ROOT/$file"
done

loop_output="$TMP_DIR/main-loop.out"
if ! run_with_timeout 3 bash -c '
    set -euo pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"

    ui_print() { printf "%b\n" "$*"; }
    ui_print_inline() { printf "%b" "$*"; }
    ui_blank() { printf "\n"; }
    ui_dim() { printf "%s\n" "$*"; }
    ui_clear() { :; }
    ui_title() {
        printf "============================================================\n"
        printf "%s\n" "$1"
        [[ ${2:-} ]] && printf "Version: %s\n" "$2"
        printf "============================================================\n"
    }
    ui_menu_item() { printf " %2s. %s\n" "$1" "$2"; }
    ui_info() { printf "[i] %s\n" "$*"; }
    ui_error() { printf "[ERROR] %s\n" "$*" >&2; }
    show_list() { :; }
    ui_pause() {
        printf "PAUSE\n"
        read -r _ || true
    }
    pause() { ui_pause; }
    load() { :; }
    run_with_backup_transaction() {
        local operation=$1
        shift
        printf "TX:%s\n" "$operation"
        "$@"
    }
    add() {
        printf "ADD_PROTOCOL:%s\n" "${is_new_protocol:-unset}"
        is_new_protocol=stale-protocol
    }

    is_core_name=sing-box
    is_sh_ver=test
    is_core_ver=1.2.3
    is_core_status=running

    is_main_menu
' bash "$REPO_ROOT" >"$loop_output" 2>&1 <<'EOF'
1

1

0
EOF
then
    cat "$loop_output" >&2
    fail 'main menu must return after completed actions without hanging'
fi

assert_count '^sing-box 管理脚本$' 3 "$loop_output" \
    'main menu title must be redrawn after each completed menu action and before exit'
assert_count '^Version: test$' 3 "$loop_output" \
    'main menu version line must be redrawn after each completed menu action and before exit'
assert_count '^sing-box: active \| Core: 1\.2\.3 \| Caddy: inactive \| Manager: unknown$' 3 "$loop_output" \
    'main menu status summary must be redrawn after each completed menu action and before exit'
assert_count '^ADD_PROTOCOL:unset$' 2 "$loop_output" \
    'main menu actions must start with clean transient protocol state'

main_q_output="$TMP_DIR/main-q.out"
if ! run_with_timeout 3 bash -c '
    set -euo pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"

    ui_print() { printf "%b\n" "$*"; }
    ui_print_inline() { printf "%b" "$*"; }
    ui_blank() { printf "\n"; }
    ui_dim() { printf "%s\n" "$*"; }
    ui_clear() { printf "CLEAR\n"; }
    ui_title() {
        printf "============================================================\n"
        printf "%s\n" "$1"
        [[ ${2:-} ]] && printf "Version: %s\n" "$2"
        printf "============================================================\n"
    }
    ui_menu_item() { printf " %2s. %s\n" "$1" "$2"; }
    ui_info() { printf "[i] %s\n" "$*"; }
    ui_warn() { printf "[WARN] %s\n" "$*"; }
    ui_error() { printf "[ERROR] %s\n" "$*" >&2; }
    show_list() { :; }
    ui_pause() {
        printf "PAUSE\n"
        read -r _ || true
    }
    pause() { ui_pause; }
    load() { :; }

    is_core_name=sing-box
    is_sh_ver=test
    is_core_ver=1.2.3
    is_core_status=running

    is_main_menu
' bash "$REPO_ROOT" >"$main_q_output" 2>&1 <<'EOF'
q
0
EOF
then
    cat "$main_q_output" >&2
    fail 'main menu q must warn and redraw before exiting with 0'
fi

assert_contains '\[WARN\] 主菜单请使用 0 退出脚本。' "$main_q_output" \
    'main menu q must warn that 0 exits the script'
assert_count '\[ERROR\] 无效输入，请重新输入。' 0 "$main_q_output" \
    'main menu q must not emit the generic invalid input error'
assert_count '^sing-box 管理脚本$' 2 "$main_q_output" \
    'main menu q must redraw the menu before exit'
assert_count '^CLEAR$' 2 "$main_q_output" \
    'main menu q must clear/redraw before exit'

add_back_output="$TMP_DIR/add-back.out"
if ! run_with_timeout 3 bash -c '
    set -o pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"

    ui_print() { printf "%b\n" "$*"; }
    ui_print_inline() { printf "%b" "$*"; }
    ui_blank() { printf "\n"; }
    ui_dim() { printf "%s\n" "$*"; }
    ui_clear() { :; }
    ui_title() {
        printf "============================================================\n"
        printf "%s\n" "$1"
        [[ ${2:-} ]] && printf "Version: %s\n" "$2"
        printf "============================================================\n"
    }
    ui_menu_item() { printf " %2s. %s\n" "$1" "$2"; }
    ui_info() { printf "[i] %s\n" "$*"; }
    ui_error() { printf "[ERROR] %s\n" "$*" >&2; }
    show_list() { :; }
    ui_pause() {
        printf "PAUSE\n"
        read -r _ || true
    }
    pause() { ui_pause; }
    load() { :; }
    run_with_backup_transaction() {
        shift
        "$@"
    }
    add() {
        ask set_protocol || return 1
    }

    is_core_name=sing-box
    is_sh_ver=test
    is_core_ver=1.2.3
    is_core_status=running

    is_main_menu
' bash "$REPO_ROOT" >"$add_back_output" 2>&1 <<'EOF'
1
0
0
EOF
then
    cat "$add_back_output" >&2
    fail '0 from the add-protocol submenu must return directly to the main menu'
fi

assert_count '^sing-box 管理脚本$' 2 "$add_back_output" \
    'returning from the add-protocol submenu must redraw the main menu title'
assert_count '^Version: test$' 2 "$add_back_output" \
    'returning from the add-protocol submenu must redraw the main menu version line'
assert_count '^sing-box: active \| Core: 1\.2\.3 \| Caddy: inactive \| Manager: unknown$' 2 "$add_back_output" \
    'returning from the add-protocol submenu must redraw the main menu status summary'
assert_count '^PAUSE$' 0 "$add_back_output" \
    'returning from the add-protocol submenu must not require an extra pause'

back_output="$TMP_DIR/list-back.out"
if ! run_with_timeout 3 bash -c '
    set -uo pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"
    ui_print() { printf "%b\n" "$*"; }
    ui_print_inline() { printf "%b" "$*"; }
    ui_blank() { printf "\n"; }
    ui_menu_item() { printf " %2s. %s\n" "$1" "$2"; }
    ui_info() { printf "[i] %s\n" "$*"; }
    ui_error() { printf "[ERROR] %s\n" "$*" >&2; }
    show_list() { :; }
    is_main_start=1
    ask list is_do_manage "启动 停止 重启" "\n请选择管理操作:\n" < <(printf "0\n")
    status=$?
    printf "status=%s\n" "$status"
    printf "is_menu_back=%s\n" "${is_menu_back:-unset}"
    printf "is_do_manage=%s\n" "${is_do_manage:-unset}"
' bash "$REPO_ROOT" >"$back_output" 2>&1; then
    cat "$back_output" >&2
    fail 'list prompts in menu mode must accept 0 without hanging or forcing the next step'
fi

assert_contains '^status=1$' "$back_output" \
    '0 in a submenu list must return non-zero so callers can skip the action'
assert_contains '^is_menu_back=1$' "$back_output" \
    '0 in a submenu list must mark a menu-back request'
assert_contains '^is_do_manage=unset$' "$back_output" \
    '0 in a submenu list must not select an action'

cancel_output="$TMP_DIR/list-cancel.out"
if ! run_with_timeout 3 bash -c '
    set -uo pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"
    ui_print() { printf "%b\n" "$*"; }
    ui_print_inline() { printf "%b" "$*"; }
    ui_blank() { printf "\n"; }
    ui_menu_item() { printf " %2s. %s\n" "$1" "$2"; }
    ui_info() { printf "[i] %s\n" "$*"; }
    ui_warn() { printf "[WARN] %s\n" "$*"; }
    ui_error() { printf "[ERROR] %s\n" "$*" >&2; }
    show_list() { :; }
    is_main_start=1
    ask list is_do_manage "启动 停止 重启" "\n请选择管理操作:\n" < <(printf "q\n")
    status=$?
    printf "status=%s\n" "$status"
    printf "is_menu_back=%s\n" "${is_menu_back:-unset}"
    printf "is_do_manage=%s\n" "${is_do_manage:-unset}"
' bash "$REPO_ROOT" >"$cancel_output" 2>&1; then
    cat "$cancel_output" >&2
    fail 'q in a submenu list must cancel without selecting an action'
fi

assert_contains '^status=1$' "$cancel_output" \
    'q in a submenu list must return non-zero so callers can skip the action'
assert_contains '^is_menu_back=1$' "$cancel_output" \
    'q in a submenu list must mark a menu-back request'
assert_contains '^is_do_manage=unset$' "$cancel_output" \
    'q in a submenu list must not select an action'
assert_contains '\[WARN\] 已取消。' "$cancel_output" \
    'q in a submenu list must emit the cancel warning'
assert_count '\[ERROR\] 无效输入，请重新输入。' 0 "$cancel_output" \
    'q in a submenu list must not emit the generic invalid input error'

pause_menu_output="$TMP_DIR/pause-menu.out"
bash -c '
    set -uo pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"
    _green() { printf "%s" "$*"; }
    _red() { printf "%s" "$*"; }
    ui_blank() { printf "\n"; }
    ui_print_inline() { printf "%b" "$*"; }
    ui_pause() { printf "UI_PAUSE_CALLED\n"; }
    is_main_start=1
    pause < <(printf "\n")
' bash "$REPO_ROOT" >"$pause_menu_output" 2>&1

assert_count '^UI_PAUSE_CALLED$' 1 "$pause_menu_output" \
    'pause must route menu-context pauses through ui_pause'

pause_cli_output="$TMP_DIR/pause-cli.out"
bash -c '
    set -uo pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"
    _green() { printf "%s" "$*"; }
    _red() { printf "%s" "$*"; }
    ui_blank() { printf "\n"; }
    ui_print_inline() { printf "%b" "$*"; }
    ui_pause() { printf "UI_PAUSE_CALLED\n"; }
    is_main_start=
    pause < <(printf "\n")
' bash "$REPO_ROOT" >"$pause_cli_output" 2>&1

assert_count '^UI_PAUSE_CALLED$' 0 "$pause_cli_output" \
    'pause must not force pauses outside menu context'

printf '[PASS] menu navigation checks\n'
