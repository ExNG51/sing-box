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
        [[ -f $file ]] && cat "$file" >&2
        fail "$description"
    }
}

assert_not_contains() {
    local file=$1
    local text=$2
    local description=$3

    if grep -Fq -- "$text" "$file"; then
        [[ -f $file ]] && cat "$file" >&2
        fail "$description"
    fi
}

assert_file_content() {
    local file=$1
    local expected=$2
    local description=$3
    local actual

    actual=$(cat "$file")
    [[ $actual == "$expected" ]] || fail "$description (expected: $expected, actual: $actual)"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sing-box-current-rollback.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

is_core=sing-box
is_core_name=sing-box
is_core_dir="$TEST_ROOT/etc/sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
is_backup_dir="$is_core_dir/backups"
is_caddyfile="$TEST_ROOT/etc/caddy/Caddyfile"
is_caddy_conf="$TEST_ROOT/etc/caddy/conf"
is_core_bin="$TEST_ROOT/usr/local/bin/sing-box"
is_sh_bin="$TEST_ROOT/usr/local/bin/sb"
is_shell_profile="$TEST_ROOT/root/.bashrc"
IS_BACKUP_ROLLBACK_SKIP_SERVICES=true

err() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

# shellcheck disable=SC1091
. "$REPO_ROOT/src/backup.sh"

type rollback_current_backup_transaction >/dev/null 2>&1 || fail 'rollback_current_backup_transaction must exist'

mkdir -p "$is_conf_dir"
printf 'base\n' >"$is_conf_dir/current.json"
printf 'old-base\n' >"$is_conf_dir/old.json"

init_backup_transaction old-transaction
safe_write_file "$is_conf_dir/old.json" 'old-mutated'
finalize_backup_transaction
old_latest_id=$(cat "$is_backup_dir/latest")

init_backup_transaction current-transaction
safe_write_file "$is_conf_dir/current.json" 'current-mutated'
current_txn_dir=$IS_BACKUP_TXN_DIR

rollback_current_backup_transaction --yes >"$TEST_ROOT/current-rollback.out"

assert_file_content "$is_conf_dir/current.json" 'base' \
    'current rollback must restore files from the active transaction'
assert_file_content "$is_conf_dir/old.json" 'old-mutated' \
    'current rollback must not rollback the previous latest transaction'
assert_contains "$current_txn_dir/manifest.json" "\"path\":\"$is_conf_dir/current.json\"" \
    'current rollback must write the active transaction manifest'
assert_not_contains "$current_txn_dir/manifest.json" "\"path\":\"$is_conf_dir/old.json\"" \
    'current rollback manifest must not include previous latest transaction paths'
assert_not_contains "$TEST_ROOT/current-rollback.out" "$is_conf_dir/old.json" \
    'current rollback plan must not include previous latest transaction paths'
[[ ${IS_BACKUP_ACTIVE:-} != true ]] || fail 'current rollback must close active backup state'

tuic_body=$(sed -n '/^tuic_rollback_after_failure()/,/^}/p' "$REPO_ROOT/src/tuic.sh")
[[ $tuic_body == *'rollback_current_backup_transaction --yes'* ]] || \
    fail 'tuic_rollback_after_failure must prefer rollback_current_backup_transaction --yes'
[[ $tuic_body == *'rollback_latest_backup --yes'* ]] || \
    fail 'tuic_rollback_after_failure must retain latest rollback fallback'

hop_rollback_body=$(sed -n '/^tuic_hop_rollback_after_failure()/,/^}/p' "$REPO_ROOT/src/tuic_port_hopping.sh")
[[ $hop_rollback_body == *'rollback_current_backup_transaction --yes'* ]] || \
    fail 'tuic_hop rollback helper must prefer current transaction rollback'
[[ $hop_rollback_body == *'rollback_latest_backup --yes'* ]] || \
    fail 'tuic_hop rollback helper must retain latest rollback fallback'
hop_rollback_count=$(grep -Fc 'tuic_hop_rollback_after_failure' "$REPO_ROOT/src/tuic_port_hopping.sh" || true)
(( hop_rollback_count >= 2 )) || \
    fail 'tuic_hop failure paths must call the rollback helper'

printf '[PASS] current transaction rollback checks\n'
