#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_file_contains() {
    local file=$1
    local text=$2
    local description=$3
    grep -Fq -- "$text" "$file" || {
        cat "$file" >&2
        fail "$description"
    }
}

assert_exists() {
    [[ -e $1 || -L $1 ]] || fail "$2"
}

assert_not_exists() {
    [[ ! -e $1 && ! -L $1 ]] || fail "$2"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

is_core=sing-box
is_core_name=sing-box
is_core_dir="$TEST_ROOT/etc/sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
is_backup_dir="$is_core_dir/backups"
is_caddy_dir="$TEST_ROOT/etc/caddy"
is_caddyfile="$is_caddy_dir/Caddyfile"
is_caddy_conf="$is_caddy_dir/conf"
is_core_bin="$TEST_ROOT/usr/local/bin/sing-box"
is_sh_bin="$TEST_ROOT/usr/local/bin/sb"

is_systemd=
is_openrc=
IS_BACKUP_ROLLBACK_SKIP_SERVICES=true

err() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

msg() {
    printf '%s\n' "$*"
}

# shellcheck disable=SC1091
. "$REPO_ROOT/src/backup.sh"

assert_rejects_dangerous_remove_paths() {
    local candidate
    local status
    local dangerous_paths=(
        "__NO_ARGS__"
        ""
        "."
        ".."
        "/"
        "/etc"
        "/etc/"
        "/usr"
        "/usr/"
        "/lib"
        "/lib/"
        "/root"
        "/root/"
        "/var"
        "/var/"
        "/tmp"
        "/tmp/"
        "*"
        "relative/path"
        "./relative/path"
        "../relative/path"
        "$TEST_ROOT/etc/sing-box/../passwd"
        "$is_backup_dir"
        "$is_backup_dir/latest"
        "/home/user/file"
        "/opt/random/file"
    )

    for candidate in "${dangerous_paths[@]}"; do
        set +e
        (
            backup_calls="$TEST_ROOT/danger-backup-calls"
            rm_calls="$TEST_ROOT/danger-rm-calls"
            rm() {
                printf '%s\n' "$*" >>"$rm_calls"
                return 0
            }
            backup_path_before_write() {
                printf '%s\n' "$*" >>"$backup_calls"
                return 0
            }

            if [[ $candidate == "__NO_ARGS__" ]]; then
                if safe_remove_path; then
                    exit 10
                fi
            elif safe_remove_path "$candidate"; then
                exit 10
            fi
            [[ ! -e $backup_calls ]] || exit 11
            [[ ! -e $rm_calls ]] || exit 12
            [[ ! -d $is_backup_dir/unsafe-remove-test ]] || exit 13
        )
        status=$?
        set -e
        case $status in
        0) ;;
        10) fail "safe_remove_path must reject dangerous path: [$candidate]" ;;
        11) fail "safe_remove_path must reject before backup for dangerous path: [$candidate]" ;;
        12) fail "safe_remove_path must reject before rm for dangerous path: [$candidate]" ;;
        13) fail "safe_remove_path must not create backup transaction for dangerous path: [$candidate]" ;;
        *) fail "dangerous path test failed unexpectedly for [$candidate] with status $status" ;;
        esac
    done
}

assert_allows_managed_remove_paths() {
    local path
    local latest_id
    local allowed_manifest
    local allowed_paths=(
        "$is_config_json"
        "$is_conf_dir/test.json"
        "$is_caddyfile"
        "$is_caddy_conf/example.com.conf"
        "$is_caddy_conf/example.com.conf.add"
        "$TEST_ROOT/lib/systemd/system/sing-box.service"
        "$TEST_ROOT/etc/init.d/sing-box"
        "$TEST_ROOT/usr/local/bin/sb"
    )

    mkdir -p "$is_conf_dir" "$is_caddy_conf" "$TEST_ROOT/lib/systemd/system" "$TEST_ROOT/etc/init.d" "$TEST_ROOT/usr/local/bin"
    for path in "${allowed_paths[@]}"; do
        mkdir -p "$(dirname "$path")"
        printf 'managed remove test: %s\n' "$path" >"$path"
    done

    init_backup_transaction allow-remove
    for path in "${allowed_paths[@]}"; do
        safe_remove_path "$path" || fail "safe_remove_path must allow managed path: $path"
        assert_not_exists "$path" "safe_remove_path must delete managed path: $path"
    done
    finalize_backup_transaction

    latest_id="$(cat "$is_backup_dir/latest")"
    allowed_manifest="$is_backup_dir/$latest_id/manifest.json"
    assert_file_contains "$allowed_manifest" '"operation":"allow-remove"' 'allowed remove transaction must write manifest'
    for path in "${allowed_paths[@]}"; do
        assert_file_contains "$allowed_manifest" "\"path\":\"$path\"" "allowed remove manifest must record path: $path"
    done
}

assert_rejects_dangerous_remove_paths
assert_allows_managed_remove_paths

mkdir -p "$is_conf_dir" "$is_caddy_conf" "$TEST_ROOT/lib/systemd/system" "$TEST_ROOT/usr/local/bin"
printf '{"old":true}\n' >"$is_config_json"
printf '{"name":"old"}\n' >"$is_conf_dir/old.json"
printf 'old caddyfile\n' >"$is_caddyfile"
printf 'old service\n' >"$TEST_ROOT/lib/systemd/system/sing-box.service"

init_backup_transaction add
safe_write_file "$is_config_json" '{"new":true}'
safe_write_file "$is_conf_dir/new.json" '{"name":"new"}'
safe_remove_path "$is_conf_dir/old.json"
safe_write_file "$is_caddyfile" 'new caddyfile'
safe_write_file "$TEST_ROOT/lib/systemd/system/sing-box.service" 'new service'
finalize_backup_transaction

latest_id="$(cat "$is_backup_dir/latest")"
backup_txn="$is_backup_dir/$latest_id"
manifest="$backup_txn/manifest.json"

assert_exists "$manifest" 'backup transaction must write manifest.json'
assert_exists "$backup_txn/config.json" 'existing config.json must be copied before overwrite'
assert_exists "$backup_txn/conf/old.json" 'existing conf/*.json must be copied before delete'
assert_exists "$backup_txn/Caddyfile" 'existing Caddyfile must be copied before overwrite'
assert_exists "$backup_txn/lib/systemd/system/sing-box.service" 'existing service must be copied before overwrite'
assert_file_contains "$manifest" '"operation":"add"' 'manifest must record operation'
assert_file_contains "$manifest" "\"path\":\"$is_config_json\"" 'manifest must record config.json path'
assert_file_contains "$manifest" "\"path\":\"$is_conf_dir/new.json\"" 'manifest must record newly created file path'
assert_file_contains "$manifest" '"existed":true' 'manifest must record existed=true entries'
assert_file_contains "$manifest" '"existed":false' 'manifest must record existed=false entries'
[[ -s "$is_backup_dir/latest" ]] || fail 'latest pointer must point to newest backup'

before_dry_run="$(cat "$is_config_json")"
rollback_latest_backup --dry-run >/tmp/backup-rollback-dry-run.out
after_dry_run="$(cat "$is_config_json")"
[[ $before_dry_run == "$after_dry_run" ]] || fail 'rollback --dry-run must not modify files'

rollback_latest_backup --yes >/tmp/backup-rollback-run.out
assert_file_contains "$is_config_json" '{"old":true}' 'rollback must restore previous config.json'
assert_exists "$is_conf_dir/old.json" 'rollback must restore deleted conf/*.json'
assert_not_exists "$is_conf_dir/new.json" 'rollback must delete manifest existed=false files'
assert_file_contains "$is_caddyfile" 'old caddyfile' 'rollback must restore previous Caddyfile'
assert_file_contains "$TEST_ROOT/lib/systemd/system/sing-box.service" 'old service' 'rollback must restore previous service'

rollback_id="$(cat "$is_backup_dir/latest")"
rollback_manifest="$is_backup_dir/$rollback_id/manifest.json"
assert_file_contains "$rollback_manifest" '"operation":"pre-rollback"' 'rollback must create a pre-rollback transaction'

cat >"$is_backup_dir/latest" <<<"$latest_id"
rm -f "$backup_txn/config.json"
if rollback_latest_backup --yes >/tmp/backup-rollback-missing.out 2>&1; then
    fail 'rollback must refuse when a backup file is missing'
fi

printf 'not json\n' >"$manifest"
if rollback_latest_backup --yes >/tmp/backup-rollback-bad-manifest.out 2>&1; then
    fail 'rollback must refuse when manifest is damaged'
fi

assert_file_contains "$REPO_ROOT/.github/workflows/release.yml" "run: bash tests/backup-rollback.sh" 'release workflow must run backup rollback checks'
awk '
    /run: bash tests\/backup-rollback\.sh/ { check_line = NR }
    /- name: tar/ { tar_line = NR }
    END { exit !(check_line && tar_line && check_line < tar_line) }
' "$REPO_ROOT/.github/workflows/release.yml" || fail 'release workflow backup rollback checks must run before the tar step'

printf '[PASS] backup and rollback checks\n'
