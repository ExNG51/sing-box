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

    show_list() { :; }
    pause() {
        printf "PAUSE\n"
        read -r _ || true
    }
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

assert_count '^------------- sing-box script test -------------$' 3 "$loop_output" \
    'main menu must be redrawn after each completed menu action and before exit'
assert_count '^ADD_PROTOCOL:unset$' 2 "$loop_output" \
    'main menu actions must start with clean transient protocol state'

add_back_output="$TMP_DIR/add-back.out"
if ! run_with_timeout 3 bash -c '
    set -o pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"

    show_list() { :; }
    pause() {
        printf "PAUSE\n"
        read -r _ || true
    }
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

assert_count '^------------- sing-box script test -------------$' 2 "$add_back_output" \
    'returning from the add-protocol submenu must redraw the main menu'
assert_count '^PAUSE$' 0 "$add_back_output" \
    'returning from the add-protocol submenu must not require an extra pause'

back_output="$TMP_DIR/list-back.out"
if ! run_with_timeout 3 bash -c '
    set -uo pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"
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

printf '[PASS] menu navigation checks\n'
