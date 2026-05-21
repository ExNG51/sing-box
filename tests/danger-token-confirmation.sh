#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file=$1
    local text=$2
    local description=$3
    grep -Fq -- "$text" "$file" || {
        cat "$file" >&2
        fail "$description"
    }
}

assert_not_contains() {
    local file=$1
    local text=$2
    local description=$3
    if grep -Fq -- "$text" "$file"; then
        cat "$file" >&2
        fail "$description"
    fi
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
LOG="$TEST_ROOT/actions.log"
trap 'rm -rf "$TEST_ROOT"' EXIT

for helper in ui_section ui_warn ui_kv ui_blank ui_confirm_token; do
    assert_match "^${helper}\\(\\)" "$REPO_ROOT/src/init.sh" \
        "src/init.sh must define $helper used by confirm_menu_danger_token"
done

run_core_mock() {
    local scenario=$1
    SCENARIO="$scenario" TEST_ROOT="$TEST_ROOT" LOG="$LOG" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail

# shellcheck disable=SC1091
. "$REPO_ROOT/src/core.sh"

ui_section() { printf 'section:%s\n' "$*" >>"$LOG"; }
ui_warn() { printf 'warn:%s\n' "$*" >>"$LOG"; }
ui_kv() { printf 'kv:%s=%s\n' "$1" "${2:-}" >>"$LOG"; }
ui_blank() { printf 'blank\n' >>"$LOG"; }
ui_confirm_token() {
    printf 'confirm:%s|%s\n' "$1" "$2" >>"$LOG"
    return 1
}
ui_pause() { printf 'pause\n' >>"$LOG"; }
msg() { printf 'msg:%s\n' "$*" >>"$LOG"; }
warn() { printf 'legacy-warn:%s\n' "$*" >>"$LOG"; }
_green() { printf 'green:%s\n' "$*" >>"$LOG"; }
safe_remove_path() { printf 'remove:%s\n' "$*" >>"$LOG"; }
safe_remove_shell_aliases() { printf 'remove-alias:%s\n' "$*" >>"$LOG"; }
backup_standard_managed_paths() { printf 'backup-standard\n' >>"$LOG"; }
begin_backup_transaction_if_needed() {
    printf 'begin-backup:%s\n' "$1" >>"$LOG"
    IS_BACKUP_ACTIVE=true
    IS_BACKUP_MANIFEST_FILES=()
    return 0
}
finalize_backup_transaction() { printf 'finalize-backup\n' >>"$LOG"; }
manage() { printf 'manage:%s\n' "$*" >>"$LOG"; }
ask() {
    printf 'ask:%s|%s|%s\n' "${1:-}" "${2:-}" "${3:-}" >>"$LOG"
    REPLY=1
    return 0
}

is_main_start=1
is_conf_dir_empty=
is_no_del_msg=
is_new_json=
is_change=
is_caddy=
is_install_sh=
is_systemd=
is_openrc=
is_dont_auto_exit=
is_core=sing-box
is_core_name=sing-box
is_conf_dir="$TEST_ROOT/conf"
is_core_dir="$TEST_ROOT/etc/sing-box"
is_config_json="$is_core_dir/config.json"
is_core_bin="$TEST_ROOT/bin/sing-box"
is_sh_bin="$TEST_ROOT/bin/sing-box"
is_log_dir="$TEST_ROOT/log"
is_shell_profile="$TEST_ROOT/root/.bashrc"
mkdir -p "$is_conf_dir" "$is_core_dir" "$TEST_ROOT/bin" "$TEST_ROOT/root"

case "$SCENARIO" in
delete-cancel)
    is_config_file="AnyTLS-example.json"
    : >"$is_conf_dir/$is_config_file"
    set +e
    del
    status=$?
    set -e
    printf 'status:%s\n' "$status" >>"$LOG"
    printf 'is_menu_back:%s\n' "${is_menu_back:-unset}" >>"$LOG"
    ;;
delete-cancel-wrapper)
    is_config_file="AnyTLS-example.json"
    : >"$is_conf_dir/$is_config_file"
    set +e
    run_with_backup_transaction delete del
    status=$?
    set -e
    printf 'status:%s\n' "$status" >>"$LOG"
    printf 'is_menu_back:%s\n' "${is_menu_back:-unset}" >>"$LOG"
    ;;
uninstall-cancel)
    set +e
    uninstall
    status=$?
    set -e
    printf 'status:%s\n' "$status" >>"$LOG"
    printf 'is_menu_back:%s\n' "${is_menu_back:-unset}" >>"$LOG"
    ;;
esac
EOF
}

: >"$LOG"
run_core_mock delete-cancel
assert_contains "$LOG" 'confirm:确认删除该配置？|DELETE' 'menu delete must ask for DELETE token'
assert_contains "$LOG" 'warn:已取消删除。' 'cancelled menu delete must warn'
assert_contains "$LOG" 'status:1' 'cancelled menu delete must return non-zero'
assert_contains "$LOG" 'is_menu_back:1' 'cancelled menu delete must return to menu'
assert_not_contains "$LOG" 'remove:' 'cancelled menu delete must not remove files'
assert_not_contains "$LOG" 'manage:' 'cancelled menu delete must not restart services'

: >"$LOG"
run_core_mock delete-cancel-wrapper
assert_contains "$LOG" 'begin-backup:delete' 'menu delete wrapper must still initialize rollback before action dispatch'
assert_contains "$LOG" 'confirm:确认删除该配置？|DELETE' 'wrapped menu delete must ask for DELETE token'
assert_not_contains "$LOG" 'finalize-backup' 'cancelled wrapped menu delete with no changes must not finalize an empty rollback'
assert_not_contains "$LOG" 'remove:' 'cancelled wrapped menu delete must not remove files'

: >"$LOG"
run_core_mock uninstall-cancel
assert_contains "$LOG" 'confirm:确认卸载 sing-box？|DELETE' 'menu uninstall must ask for DELETE token'
assert_contains "$LOG" 'warn:已取消卸载。' 'cancelled menu uninstall must warn'
assert_contains "$LOG" 'status:1' 'cancelled menu uninstall must return non-zero'
assert_contains "$LOG" 'is_menu_back:1' 'cancelled menu uninstall must return to menu'
assert_not_contains "$LOG" 'remove:' 'cancelled menu uninstall must not remove files'
assert_not_contains "$LOG" 'backup-standard' 'cancelled menu uninstall must not record backup changes'
assert_not_contains "$LOG" 'manage:' 'cancelled menu uninstall must not stop services'

printf '[PASS] danger token confirmation checks\n'
